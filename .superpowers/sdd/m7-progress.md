# chez-http-server — ledger archive: M7, the scheduler and awaiting handlers

M7's entries, moved verbatim from `progress.md` on 2026-10-05 (its lines 3794–4205 at 64761cb). The mutation log is `m7-mutations.md`; the spine is `progress.md`.

---

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

M7.2 THIRD STEP: `sleep-ms` and `with-deadline` (feat/m7.2-timed-waits).
- `(http-server heap)`, pure: a binary min-heap of the times a loop's waits wake at, by time and then by the order put in, each entry keeping its place, so one leaves the middle in log time.
- `(http-server private waits)`: `sleep-ms` and `with-deadline` over the heap, with the loop's clock and a timer of their own (`waits-clock!`), fired by `waits-fire!`, armed for the earliest and stopped when nothing is left. A deadline is in force until its thunk is left, once, by a return, a raise or a continuation, held by a `dynamic-wind` whose after thunk a park runs too (the review's first and third); a raise a handler outside continues does not leave it, and every value the thunk returns comes back; once passed, it ends the wait in progress, taking back a sleep, or the next one before anything is armed, and every later wait inside it. A wait it ends raises `&deadline-passed`, an `&error` of `(http-server awaiting)`; a resume after it is late (R4). A coroutine keeps what its deadlines need, the wait it is parked on and how many have passed (`coroutine-waits`, the scheduler's slot); the scheduler tells a park from a leaving (`coroutine-suspending?`).
- `(http-server private shell)`: the loop's waits get the loop's clock, brought up to date as it is read, and a timer of their own, made when first started; like the tick timer it is closed by a shell that serves no more, when nothing is armed (`release-waits-timer!`), and made again by the next timed wait. `shell-waits-timed` reads how many are armed, for the checks.
- The facade exports `sleep-ms`, `with-deadline`, `&deadline-passed` and `deadline-passed?`; `docs/handlers.org`'s "Waiting" gains them.
- The checks: the heap suite, seven, its oracle a plain list, played against 5,000 steps from a fixed seed; the waits suite's seventeen more, on a clock it sets, four of them added after: the review's three, and the sleep due at its deadline's own time (the fourth step's FOUND); in the shell suite, a handler that holds the loop 30 ms, then sleeps 20 ms, sleeping 18 ms or more by the monotonic clock, and one whose deadline of 10 ms ends a sleep of a minute, answered at once, nothing left armed; and a sleep after a shell has served its last, the timer made again.

FOUND WHILE BUILDING, each fixed with its check:
- The timer of the waits, first left for the loop's teardown to close, reddened the shell suite's "and no handle is left on the loop": it is now closed as the tick timer is.
- A coroutine's list of its deadlines in force, kept at first, was written and never read: taken out.
- `make check-imports` greps text: two comments in pure libraries that named the private waits library reddened it, and were reworded.
- The docs' first example of a deadline returned a response from an exception handler; the deadline's raise is not continuable, so its handler may not return. The example now uses `guard`.
- Seven of the step's first thirty-six mutants survived, each a check too weak to see it, and each check was made stronger (m7-mutations.md).

Measured on the step's tree (2026-10-02, Darwin arm64): `make test` green, forty-seven suites, 1,518 expected passes (1,492 + 26), every pin ok.

Watched to fail (m7-mutations.md, M7.2's third step, and the review's fixes): forty mutants on the step's tree, M7H-13, M7T-25 and the review's M7T-26 to M7T-30 among them, and M7T-8 to M7T-10 withdrawn with the exception handler they cut; every check the step added is reddened by one.

Records: decision 0015's choices of the third step; decision 0005's amendment, a second timer a loop; design §2's and §3.1's notes; the scheduler's and the shell's headers; `docs/handlers.org`.

Size: 1,066 inserted lines of code and tests, 56 deleted.

NEXT: the fourth step, `resolve`, stacked on this one.

M7.2 FOURTH STEP: `resolve` (feat/m7.2-resolve).
- `(http-server private waits)`: `(resolve host)`, a wait on the loop's resolver (`waits-resolver!`): the addresses, as strings, in the resolver's order, or `&resolve-error`, an `&error` of `(http-server awaiting)` whose reason is the resolver's error, with `host` among its irritants. A deadline that ends one cancels its lookup if it has not begun; its answer after is late (R4), plan §14's own example.
- `(http-server private shell)`: the loop's resolver is `uv-getaddrinfo!`, stream sockets alone, so each address is answered once; a failure answered by its errno's name (EAI_...); a name refused at the call, empty, over 255 octets or with a NUL in it, answered `invalid-name` at once, the refusal caught by a handler that jumps out on a one-shot continuation (the review's second), so `resolve` raises `&resolve-error` for any name that does not resolve; a cancel, `uv-cancel!`.
- The facade exports `resolve`, `&resolve-error`, `resolve-error?` and `resolve-error-reason`; `docs/handlers.org` gains them.
- The checks: the waits suite's five more, its resolver scripted; in the shell suite, `localhost` answered what `uv-getaddrinfo!` itself answers, an empty name, one with a NUL and one of 300 characters `invalid-name`, and `a..b`, a name with an empty label, EAI_NONAME, which the resolver answers without asking the network (the review's fourth).

FOUND WHILE BUILDING, each fixed with its check or its record:
- A sleep due at its deadline's own time, the deadline armed first, comes out of one advance after it: the deadline ended the wait and took the sleep back, and then the sleep's own wake came, logged as a late resume. A sleep now wakes only if it has not been taken back. The third step's check and fix, carried into its layer (M7T-25).
- An ordinary request through a real socket cost 117 to 130 B more on the branch than on main (scratch `await-alloc.sps`): bisected to the third step's `release-waits-timer!`, which read a table of the shell library's own. No changed line runs for a request, and Chez's optimizer output differed in that procedure alone (`expand/optimize-output`): the cost is closure conversion's. Each request's code reaches the procedure through calls Chez knows (`dispatch!`, `arm!`, `start-ticking!`, whose timer's callback calls `tick!`, then `server-dispatch!` and `release-timer!`), so the closures each request makes carried the table. Each shell now keeps the box of its loop's waits' timer, and the procedure reads nothing of the library's own; an ordinary request costs what main's does. Recorded in its comment; no check sees a shell's bytes a request (below).

Measured on the step's tree, the finished one (2026-10-02, Darwin arm64): `make test` green, forty-seven suites, 1,524 expected passes (1,518 + 6), every pin ok. What the shell, the client and chez-libuv's Scheme side allocate together a request (scratch `await-alloc.sps`, a client on the shell's loop sending 10,000 keep-alive GETs one at a time, after 1,000; two rounds, the trees alternating, nothing else running):
- an ordinary handler: 13,543 to 13,560 B, where main's (f5532ee) costs 13,542 to 13,577;
- one that answers `awaiting` and does not wait: 15,734 to 15,736 B, where main's costs 17,865 to 17,885: the first step's 2.1 KB;
- one that waits once on `await`, resumed as it registers: 15,845 to 15,855 B; resumed from the drain once it has parked: 16,166 to 16,172 B;
- each 85 to 88 µs on either tree, the loop's round trip; 2.7 to 2.8 turns a request.

On Linux, in Docker's `chez-libuv-valgrind:10.4.1` image (698eba6; Linux 6.12.76-linuxkit aarch64, Chez 10.4.1), from a copy of the tree made with `COPYFILE_DISABLE=1`, curl and ab installed: `make test`, less its submodule and pin checks, forty-seven suites, 1,524 expected passes. The same costs a request, two rounds: an ordinary handler 12,987 B, as main's; one that answers `awaiting` with no wait 15,361 B, where main's costs 17,411; one that waits once on `await`, resumed as it registers, 15,505 B, and resumed from the drain, 15,509 B; the branch 18.2 to 19.9 µs a request, main's 20.8 to 22.1, two turns each.

Watched to fail (m7-mutations.md, M7.2's fourth step, and the review's fixes): sixteen mutants of the step's own, the review's M7L-15 to M7L-18 among them, and M7L-7 and M7L-8 withdrawn with the shell's own tests of a name, which they cut; each reddens a check but M7L-11, the scope survivor; every check the step added is reddened by one.

Records: decision 0015's choices of the fourth step; plan §14's built note; the shell's header; `docs/handlers.org`; the README's status.

Size: 312 inserted lines of code and tests, 44 deleted.

M7.2 BUILT, the four steps proved each on its own tree, the review's fixes in (2026-10-02):
- Each step's tree made afresh, main at f5532ee with the step's files and those of the steps below laid in, `make check-imports` and every suite run there: the first, forty-five suites and 1,482 expected passes; the second, forty-six and 1,492; the third, forty-seven and 1,518; the fourth, the finished tree, forty-seven and 1,524.
- Each step's mutants on its own tree: five, fifteen and forty, and on the finished tree all seventy-six (m7-mutations.md, "The review's fixes"). Every mutant loads, and each reddens a check but M7L-11, the scope survivor; every check a step added is reddened by its own step's mutants on its own tree: four, eleven, twenty-six and six.

Size, inserted and deleted lines of code, tests and the Makefile, each step against the one below it: the first 71 and 8; the second 402 and 33; the third 1,066 and 56; the fourth 312 and 44; the slice, against main, 1,767 and 57. `docs/handlers.org` and the README's status: 78 inserted lines and 1 deleted, against main.

NEXT: the four stacked PRs, merged bottom up on the owner's "do closing ritual" once CI is green on each head. Then M7.3 (plan §14), three shells under one contract, when the owner asks.

MERGED to main on 2026-10-02, on the owner's "do closing ritual": **M7.2, as four stacked PRs.**
- **#98, the scheduler without `guard`,** as e9538d2. Its squash tree (bd8ee9a) is the tested tip's, 24a7e9c's, and its parent is f5532ee. It merged first and kept its branch, since #99 was based on it.
- **#99, `await`,** as efb9d15. It was retargeted to main and rebased from #98's tip, 24a7e9c. The rebased tip, aadb393, has the tested tree (6337bcd, 154ebc8's), and so does the squash, whose parent is e9538d2.
- **#100, `sleep-ms` and `with-deadline`,** as 7dd450e. It was retargeted to main and rebased from #99's tip before its rebase, 154ebc8. The rebased tip, d93f5e5, has the tested tree (0de2157, 45947d9's), and so does the squash, whose parent is efb9d15.
- **#101, `resolve`,** as 25282fd. It was retargeted to main and rebased from #100's tip before its rebase, 45947d9. The rebased tip, c4d741c, has the tested tree (ee1d6e6, 8a5d9f9's), and so does the squash, whose parent is 7dd450e.
- **CI.** Each merged on `linux` SUCCESS at its head: #98 on 24a7e9c (run 37061901217); #99 on aadb393 (run 37062456911); #100 on d93f5e5 (run 37062668021); #101 on c4d741c (run 37062856436). Each log holds its step's count: 1,482, 1,492, 1,518 and 1,524 expected passes.
- **Branches.** All four deleted, local and remote, and refs pruned. No PR is open. #101's `--delete-branch` deleted its branch, local and remote, and this time switched this checkout to main and fast-forwarded it; the lower three were deleted by hand.

`make test` green on main: forty-seven suites, 1,524 expected passes, every pin ok.

DONE and merged (e9538d2, PR #98; efb9d15, PR #99; 7dd450e, PR #100; 25282fd, PR #101): **M7.2.**
- A handler that answers `awaiting` waits with four verbs, which the facade exports with it (decision 0015): `await`, whose resume is one-shot, a late one logged as `late-resume` with its verb (R4); `sleep-ms` and `with-deadline`, timed to the millisecond by one libuv timer a loop over a binary heap, `(http-server heap)`; and `resolve`, through `uv-getaddrinfo!`, a name refused at the call answered `invalid-name`. A reader's or a producer's wait goes on when its connection closes.
- A coroutine costs 374 B where M7.1's cost 3,756 B: its raise is caught by a handler that jumps to the drain, not by a `guard`. Through a real socket, a handler that answers `awaiting` and does not wait costs 2.1 KB less a request than on main, and an ordinary one what it did.
- A /code-review high found seven, all fixed on the owner's word by form, three of them bugs. Seventy-six mutants on the finished tree, each reddening a check but M7L-11, a scope statement.
- The fake shell's path for a waiting handler is M7.3's, with a scripted clock, timer and resolver for its waits (`waits-clock!` and `waits-resolver!` take them).

NEXT: M7.3 (plan §14), three shells, one contract: the contract test plays its scripts through the coroutine shell as well (brief item 5), and a handler awaiting `uv-getaddrinfo!` inside a pipelined connection keeps the responses in order (the brief's exit). On a fresh branch cut from main after this commit, when the owner asks.

M7.3: THREE SHELLS, ONE CONTRACT, on the owner's "lets start M7.3". Two stacked steps, cut from main at bc570a4: feat/m7.3-fake-coroutines, then feat/m7.3-waits-in-order, the second on the first; 2026-10-02, Darwin arm64, Chez 10.4.1 `tarm64osx`, libuv 1.52.1. Tests and records only: no file under `src/` changes.

MEASURED FIRST (scratch `order-probe.sps` and `direct-vs-coro.sps`, on main's tree):
- A pipelined `/resolve` and `/after` in one write, through the libuv shell, each handler answering `awaiting`: reading stops at `/resolve`'s end, and `/after`'s handler is called once `/resolve`'s response is written and its write has completed; so too for `/sleep`, `/wait-none` and `/after`. The core reads no request past one whose handler has not answered (decision 0004), so no later request's handler exists while one waits, and plan §14's mutation for the order row, "the coroutine shell resumes a later request's handler first", cannot be made in v1. Its nearest shapes, on that connection: a waiting connection's newest call started first, and the scheduler's ready queue run newest first, each left the responses in order, `(/resolve /after)` and `(/sleep /wait-none /after)`. The core feeding the request behind at once broke the parser (byte-machine's `lifecycle-violation`, `parser-resume!` on a parser not paused), which the run raised again. The coroutine shell answering `awaiting` at once had `/resolve` answered 500 and `/after` never.
- The contract's 21 scripts, the 19 played to the direct shell and the 2 that stall, through the libuv shell and through it with its handler answering `(awaiting (lambda () (held-handler req)))`: the bytes each client read were the same in all 21, each Date's value aside. The traces were the same in 3 (the two handlers that raise, the request with no Host); the same but for credit in 15, `credit` after the handler's answer and `body-credit` events (decision 0014 item 2); in another order in 1, a reader that raises at its first piece, whose end the coroutine shell asks for before the piece's failure is known; and in 2 only by their ticks' times, which are separate runs'.

DECIDED on the owner's word (2026-10-02), by form, on those measurements: **"Answered at once (Recommended)"**: the order row's mutation is the coroutine shell answering a waiting handler before its thunk has ended, and the plan's mutation and its two nearest shapes are recorded as unmakeable in v1. Weighed: "The core reads on", red but by a parser contract violation that ends the suite, and "No mutant, recorded". And **"Bytes across all three (Recommended)"**: each libuv shell's trace is held to a fake made the same way, and the coroutine shell's bytes to the direct shell's, Dates aside. Weighed: "Traces, credit aside", which needed exceptions for 3 of the 21 scripts, and "Each with its fake". Plan §14's M7.3 note and design §8.4's note record both, and the plan's note cuts M7.3 into two steps: the fake's coroutine path and every script through the coroutine shell; then the fake's waits, handler code that waits, and the order row.

DECIDED on the owner's word (2026-10-02), by form, after the plan-vs-landed walkthrough: **"Review, then 2 stacked PRs (Recommended)"**: a /code-review high of the uncommitted branch first, its findings fixed on the owner's word, then one PR a step, each proved green on its own tree before its commit. Weighed: the two PRs with no review, and the review then one PR.

M7.3's REVIEW (2026-10-02, on the owner's form): a /code-review high of the uncommitted branch, both steps, found seven:
1. the fake dropped the libuv shell's close checks, on its header's claim that no event can close a connection between a call's ask and the call; but a call parked on a wait spans replayed events, so a read's error given meanwhile would close the fake's connection and the call's answer still be dispatched and traced, where the libuv shell drops it (decision 0015 item 4). Latent: no script closes a connection while a call waits;
2. nothing held the coroutine pass to the coroutine path: with the suite's `waiting` made the identity (M7C-3, measured surviving on both steps' trees) it played the direct shell twice, every check green;
3. the replay ends the fake's waits only where the suite's helpers mark their ends, and `resolved` marked nothing at a deadline's raise, while the fake's cancel raised;
4. `responses`, `bytes-of`, `spaced` and `looked-up` copied the socket lane's own;
5. `make-fake-connection`'s signature still typed its handler `(Request -> Response)`;
6. a comment left unreflowed by an edit;
7. `fake-shell-answer-lookup!` answered the host it looked up, which nothing read.

DECIDED on the owner's word (2026-10-02), by form: **"Fix all seven (Recommended)"**. Weighed: all but moving the helpers, and the three gaps alone.

FIXED as decided, before the first commit, each in the step it belongs to, with its check or its mutant (m7-mutations.md, "The review's fixes"):
- the first, in the first step, its check in the second, which has the waits: the fake keeps `closing?`, set by its close; a call that ends then has its answer dropped, and the connection makes no more calls. The contract suite's own row: a reader's piece asleep when a read's error closes the connection, its sleep ending once, its credit dropped and its end never called; red before the fix, and under either check taken out (M7F-17, M7F-18);
- the second, in the first step: each script through the coroutine shell is checked to have its handler answer on credit wherever the direct shell's answered with none, 18 checks; M7C-3 reddens 16, the other two scripts' handlers failing in both shells;
- the third, in the second step: `resolved` marks a deadline's raise as the timer's, the fake's cancel drops its lookup, and THE WAITS' MARKS says the handler code waits through `slept` and `resolved` alone. A script whose deadline of 0 ms passes before its lookup can answer, since a turn runs its timers before it polls, then a second lookup; red before the fix, the fake never answering, and then, with `resolved` alone fixed, the fake's cancel raising; red under either fix taken out (M7C-7, M7F-19);
- the fourth, in the second step: the four live in `(shell-testing)`, as `responses`, `bytes-between`, `spaced`, and `looked-up`, which takes the loop and a cap; the socket lane and the contract use them. The shared `responses` dropping its last response reddens the order row and 46 of the socket lane's checks (M7C-8);
- the fifth and the sixth, in the first step; the seventh, in the second.

M7.3 FIRST STEP: the fake's coroutine path, and every script through the coroutine shell (feat/m7.3-fake-coroutines).
- `tests/fake-shell.sls`: a fake connection keeps a scheduler of its own, `(http-server private scheduler)`'s, drained once each outermost dispatch has ended: its handler calls are made there, as the libuv shell makes them after libuv's turn, and its coroutines run there. A handler that answers `awaiting` has its thunk run on a coroutine and its answer dispatched on credit; until the next request's handler is called, its reader's pieces and end and its producer are called on coroutines, one at a time, in order, a streaming reader's piece credited once taken; a reader's end that answers `awaiting` waits too. As in the libuv shell, a call that ends once its connection has closed has its answer dropped, and the connection makes no more calls (the review's first). Its handler's call keeps no check for a connection closed before it: the fake drains after every dispatch, so nothing comes between.
- `tests/test-contract.sps`: the coroutine shell, the libuv shell whose handler answers every request `(awaiting thunk)`, the thunk the same handler's call. The 18 scripts whose requests reach a handler play to it too, replayed to a fake made the same way, each held by the contract's three checks and two more: the client read what the direct shell's client read, each Date's value aside; and the handler answered on credit wherever the direct shell's answered with none (the review's second). The request the core refuses moves to a list of its own, and the scripts that stall stay the direct shell's: through the coroutine shell they would play the direct shell again, 12 checks no mutant of the coroutine path could redden (measured). The suite credits only a shell made on credit, and the replay gives the fake only the suite's credit: a waiting reader is credited by each shell itself (found building the second step, where the direct shell's waiting reader was credited twice, by each shell and by the suite).

Measured on the step's tree (2026-10-02, Darwin arm64): `make test` green, forty-seven suites, 1,614 expected passes (1,524 + 90), every pin ok. Red first: the coroutine pass, played before the fake had its coroutine path, failed 32 checks, the fake answering `awaiting` as a response, which the core answers 500.

Watched to fail (m7-mutations.md, M7.3): twenty-two mutants on the step's tree, M7.1's M7A-5, M7A-6 and M7A-9 among them; thirteen redden its checks, and every one of the 91 checks it added or changed is reddened by one. Eight survive the step's tree for want of handler code that waits, each red on the finished tree; M7F-10, M7.1's M7B-7 re-cut, survives both trees, a scope statement.

Records: plan §14's M7.3 note; design §8.4's note.

Size: 312 inserted lines of tests, 109 deleted.

NEXT: the second step, handler code that waits and the order row, stacked on this one.

M7.3 SECOND STEP: handler code that waits, and the order row (feat/m7.3-waits-in-order).
- `tests/fake-shell.sls`: a fake connection's waits, `(http-server private waits)`'s, scripted: their clock the injected one; their timer the test's, `fake-shell-fire-waits!`; their resolver the test's, `fake-shell-answer-lookup!`, one lookup at a time, a deadline's cancel dropping it (the review's third).
- `tests/test-contract.sps`: handler code that waits, played to the direct shell: a sleep; a deadline that passes while its handler sleeps; a lookup of localhost, and of a name that does not resolve; a deadline of 0 ms that passes before its lookup can answer, then a second lookup (the review's third); a reader that sleeps at each piece; a producer that sleeps before each call; an ordinary handler's reader whose end waits; and the brief's exit, a lookup inside a pipelined connection, then an ordinary request and a sleep, which THE ORDER ROW holds to the order they were asked in, the lookup's answer what uv-getaddrinfo! itself answers. THE WAITS' MARKS: the handler code waits only through `slept` and `resolved`, which mark in the libuv shell's events where each wait ended, and the replay ends the fake's wait there. The replay moves the fake's clock inside its guard, so an event out of time is a trace entry, not the suite's end: under the order row's mutation a wait went on past its connection's close (decision 0015 item 4), marked its end among the next script's events, earlier than that fake's start, and ended the suite before the order row ran. The suite's own row for the review's first fix.
- `tests/shell-testing.sls`, `tests/test-shell.sps`: `responses`, `bytes-between`, `spaced` and `looked-up`, shared (the review's fourth).

Measured on the step's tree, the finished one (2026-10-02, Darwin arm64): `make test` green, forty-seven suites, 1,643 expected passes (1,614 + 29), every pin ok. On Linux, in Docker's `chez-libuv-valgrind:10.4.1` image (698eba6; Linux 6.12.76-linuxkit aarch64, Chez 10.4.1), from a copy of the tree made with `COPYFILE_DISABLE=1`, curl and ab installed: `make test`, less its submodule and pin checks, forty-seven suites, 1,643 expected passes.

Watched to fail (m7-mutations.md, M7.3): thirty-three mutants on the finished tree, the first step's twenty-two among them; each reddens a check but M7F-10, and every one of the 119 checks the slice added or changed is reddened by one, the suite's row for the review's first fix too. The order row: M7O-1, decided by form, and M7A-6, M7A-9, M7C-4 and M7C-8; the plan's mutation, as near as v1 lets it be made, M7O-2 and M7O-3, leaves it green.

Records: design §8.4's note, its sentence on the marks; plan §14's built note; the README's status.

Size: 295 inserted lines of tests, 52 deleted.

M7.3 BUILT, the two steps proved each on its own tree, the review's fixes in (2026-10-02):
- Each step's tree made afresh, main at bc570a4 with the step's files and those of the step below laid in, `make check-imports` and every suite run there: the first, forty-seven suites and 1,614 expected passes; the second, the finished tree, forty-seven and 1,643.
- Each step's mutants on its own tree: twenty-two on the first, and on the finished tree all thirty-three (m7-mutations.md, M7.3). Every mutant loads; on the finished tree each reddens a check but M7F-10, the scope survivor. Every check a step added is reddened by its own step's mutants on its own tree: 91 of 91 on the first, 119 of 119 on the finished tree.

Size, inserted and deleted lines of tests, each step against the one below it: the first 312 and 109; the second 295 and 52; the slice, against main, 600 and 154. No file under `src/` changes.

NEXT: the two stacked PRs, merged bottom up on the owner's "do closing ritual" once CI is green on each head. Then the M7 exit (plan §14): each of R1 to R5 with a mutation that goes red, and the budget spike run again, an idle connection carrying no coroutine, when the owner asks.

MERGED to main on 2026-10-02, on the owner's "do closing ritual": **M7.3, as two stacked PRs.**
- **#102, every script that reaches a handler through the coroutine shell,** as fbab4a2. Its squash tree (8179beb) is the tested tip's, b85a46e's, and its parent is bc570a4. It merged first and kept its branch, since #103 was based on it.
- **#103, handler code that waits and the order row,** as 3317e8d. It was retargeted to main and rebased from #102's tip, b85a46e. The rebased tip, 9b33851, has the tested tree (80cda3d, a5c2724's), and so does the squash, whose parent is fbab4a2.
- **CI.** Each merged on `linux` SUCCESS at its head: #102 on b85a46e (run 37078945265); #103 on 9b33851 (run 37083318030). Each log holds its step's count: forty-seven suites, 1,614 and 1,643 expected passes.
- **Branches.** Both deleted, local and remote, and refs pruned. No PR is open.

`make test` green on main: forty-seven suites, 1,643 expected passes, every pin ok.

DONE and merged (fbab4a2, PR #102; 3317e8d, PR #103): **M7.3.**
- The fake shell has the libuv shell's coroutine path and scripted waits. The contract plays every script that reaches a handler through the coroutine shell, and handler code that waits through the direct shell, and holds the brief's exit: a handler awaiting a lookup inside a pipelined connection keeps the responses in order.
- Decided by form: the plan's order-row mutation cannot be made in v1, and the row's is the shell answering a waiting handler at once; the three shells are held to the same bytes, each libuv shell's trace to its own fake.
- A /code-review high found seven, all fixed on the owner's word by form. Thirty-three mutants on the finished tree, each reddening a check but M7F-10, a scope statement.

NEXT: the M7 exit (plan §14): each of R1 to R5 with a mutation that goes red, and the budget spike run again, an idle connection carrying no coroutine. On a fresh branch cut from main after this commit, when the owner asks.

M7 EXIT (plan §14), on the owner's word: "start M7 exit". Measured on main at 3b1bb75, 2026-10-02, Darwin arm64, Chez 10.4.1 `tarm64osx`, libuv 1.52.1; built 2026-10-03 as two stacked steps: fix/waiting-piece-values, cut from main, then feat/m7-exit on it. Mutation log: m7-mutations.md, "The M7 exit".

Gathered before the first test, from the brief's M7 and plan §14:
- the brief's exit: a handler awaiting `uv-getaddrinfo!` inside a pipelined connection keeps response order; R1–R5 each have a mutation that goes red;
- plan §14: each of R1–R5 has a mutation that goes red; the budget spike run again shows an idle connection's heap unchanged, an idle connection carrying no coroutine.

Met before this branch: the order row (M7.3); the brief's M7 scope, the scheduler with `poll!` injected and the phase cell (M7.1), one-shot resume cells (M7.2), `await` and `with-deadline` (M7.2), and the contract extended to the coroutine shell (M7.3).

MEASURED, before the form:
- **R1–R5, on the merged tree.** Each invariant's mutants from M7.1 and M7.2, eighteen, the latest cut of each (M7.2's re-cuts of M7.1's that its rewrite had orphaned), against all forty-seven suites, three at a time, from a frozen copy of the tree: every one loaded, and every one reddened a suite but M7B-6, M7.1's scope statement for R5. R1, R2, R4 and R5 each have a mutant that reddens its own rows: R1's scheduler row M7W-13, M7S-D2 and M7S-O, and the shell suite's check of where a handler is called M7B-4 (design §5.3's) and M7S-Q; R2's rows M7W-8 and M7S-Q, the shell suite's M7B-4 too; R4's four rows M7W-1 (design §5.3's), M7W-4, M7W-15 and M7W-10; R5's row M7W-14, M7S-K and M7R-3. Design §5.3's first, M7S-A, the poll's modes swapped, reddens the yield row, the clients, contract and serve suites, and the shell suite, which raised.
- **R3's own mutant no longer reached R3's row.** M7S-B, a coroutine's end returning normally, reddened four suites (scheduler and shell, each raised; waits 40 failures; contract 52), but the scheduler suite raised in its sixth check, after its fourth and fifth failed, and R3's row is its eleventh. At M7.1's tree (72ac3fb) it reddened R3's row, then raised: inside the `guard`, Chez made each coroutine's continuations full ones, so a return into the first one was let through, and only R3's row saw the turns after it go wrong. From M7.2's first step (e9538d2, measured there too) a coroutine's raise is caught by a handler, the continuations stay one-shot, and Chez refuses the return at once: "attempt to invoke shot one-shot continuation", at the first coroutine that raises, or parks and ends, and the coroutine running stays set, so every drain after it is refused. M7.2 re-ran its own mutants, not M7.1's. Moved first in a scratch copy of the suite, R3's row passed with the other twenty, and M7S-B reddened it, reading that refusal, then the suite raised, as at M7.1. Taking each check's raise as its own failure would not do: every check after the first coroutine that ends would fail at its drain, whatever it checks.
- **The budget spike, run again** (`research/spike/m7-exit-budget.sps`, new: `m5-exit-budget.sps`'s holds, each GET answered at once, or by a handler that waited on a coroutine, sleeping 0 ms or looking localhost up; two runs, 48 holds each, of 100 and then 500 connections idle after 1, 10, 50 and 200 GETs). Every hold was satisfied, the client exiting 0, nothing armed in the waits, and of 1,252,800 coroutines made, none was in the heap after a full collection. A connection held 1,875 to 1,971 B of heap whose handler answered at once (median 1,923), 1,915 to 1,924 B after sleeps (1,919) and 1,911 to 1,920 B after lookups (1,919). 2,000 coroutines parked at an `await` held 3,637 and 3,639 B each.
- **Before M7 and after.** `m5-exit-budget.sps`, the same file on both, run on the tree before M7 (4a7748b, its `src` and `tests` by `git archive`, the pins the same) and on M7's, alternating, two runs each: 1,803 to 1,969 B a connection before (median 1,880, sixteen readings) and 1,885 to 2,045 after (median 1,940). M7 adds three fields to a connection's record (`waits?`, `calls`, `calling?`): 19 mutable fields cost 160 B and 22 cost 192, measured. An idle connection's fields, listed after a GET on each tree, differ in those three alone, `#f`, `()` and `#f`, holding nothing. The parts priced fresh are the same on both: the core's state 400 B, the adapter's context 32, a parser 592, chez-libuv's TCP handle about 208 on the heap, a wheel entry 48. The shell logs nothing per connection on either (one entry, `listening`).
- **A check of it, prototyped** in a scratch copy of the shell suite: a handler that sleeps, looks localhost up and meets a deadline of 0 ms, its reader's piece and end sleeping, and its producer sleeping before each call; once it is answered and its connection idle, a full collection leaves none of the six coroutines they ran on. M7H-6, the heap's slot not cleared once its entry leaves, reddened it, that check alone in the shell suite. A scheduler keeping its drain's continuation after a coroutine runs survived: that continuation has always been used by then, and a used one-shot continuation holds no frame. The suite took 4.33 to 4.35 s with it, main's 4.25 to 4.30.
- **Found by that prototype: a waiting handler's reader whose piece answers no values fails the handler.** Its piece first ended with `(sleep-ms 0)`, which answers no values: the client read 500, and the shell logged `handler-failed`, "returned 0 values to single value return context". On main, a POST whose reader's piece answers `(values)` reads 200 from an ordinary handler and 500 from one that answers `awaiting`; one whose piece ends with `(sleep-ms 0)`, 500; one whose piece answers a value after its sleep, 200. A coroutine's thunk answers one value, its end's, and both shells call a waiting reader's piece as that thunk, where `read-body` takes a piece `(Bytevector Nat Nat -> Any)` whose answer is not read.

DECIDED on the owner's word (2026-10-03), by one form, on those measurements:
- **"R3's check first (Recommended)":** R3's row runs first in the scheduler suite. Weighed: "A suite of its own", R3's row in a program of its own, a forty-eighth suite; and "Record as is", the four suites' red counted for R3.
- **"Fix, its own PR (Recommended)":** neither shell reads what a waiting reader's piece answers; a shell-suite row, red on main; the contract's sleeping reader ends with its sleep, red if either shell is left unfixed; the exit's PR stacked on it. Weighed: "Fix in the exit's PR", and "Record it for M8", a note that a waiting reader's piece must answer a value.
- **"Spike and a check (Recommended)":** the shell suite checks that an idle connection carries none of the coroutines its handler, reader and producer ran on. Weighed: "Spike only", the readings recorded as at the M4 and M5 exits.

DECIDED on the owner's word (2026-10-03), by form, after the plan-vs-landed walkthrough: **"Review, then 2 stacked PRs (Recommended)"**: a /code-review high of both steps, uncommitted, first. Weighed: "2 stacked PRs now".

THE M7 EXIT'S REVIEW (2026-10-03): a /code-review high of both steps found four, all in tests:
1. the idle check read its wait, its kinds and its collection as arguments of one `list` call, whose order Chez does not fix: a collection made before the wait would read an empty `noted`, and the check pass whatever the shell kept;
2. `/read-sleeps`, reordered to end its piece with its sleep, copied each piece before sleeping, so the contract no longer held that a waiting reader's piece is whole after the reader has slept;
3. R3's row runs first only by its place in the file, which no check holds;
4. the first step's shell check read its wait and its responses the same way as the first, a spurious red at worst.

DECIDED on the owner's word (2026-10-03), by form: **"Fix 1, 2, 4; note 3 (Recommended)"**. Weighed: "Fix all four", R3's row in a suite of its own, which the first form weighed and left; and "Fix 1 and 4 only".

FIXED as decided, before the first commit, each in the step it belongs to: the second and fourth in the first step, the first in the second. Each check binds its wait before it reads anything (`let*`). `/read-sleeps`' reader sleeps, keeps the piece, then answers `(values)`, so it holds both again. The third is noted in the scheduler suite's header and in m7-mutations.md, the M7 exit. Then each step's tree was made afresh, its `make test` run, and all its mutants run again, against every suite: the first, forty-seven suites and 1,644 expected passes, its thirty-five, 30 of 30 checks still; the finished tree, forty-seven and 1,645, its sixty-nine, 60 of 60 still, `/read-sleeps`' second check now reddened by M7F-7 too. Under M7S-N the shell suite now stops after seven failures, where it stopped after twenty-four: the two shell checks bind their waits outside the check, as the suite's others do, so a raise out of a wait ends the suite there.

M7 EXIT, FIRST STEP: a waiting handler's reader may answer a piece with no values (fix/waiting-piece-values).
- `src/http-server/private/shell.sls`: the piece of a waiting handler's reader is called on its coroutine, as before, and the coroutine answers #t after it: what the piece answers is not read, so it may answer no values, as an ordinary reader's may, and as one that ends with a sleep does.
- `tests/fake-shell.sls`: the same, and its header says so.
- `tests/test-shell.sps`: `/await-none`, a handler that waits and reads the body with a reader whose piece ends with `(sleep-ms 0)`: its client reads the response, 200. Red first: on main the client read 500.
- `tests/test-contract.sps`: `slept` answers no values, as `sleep-ms` does, and `/read-sleeps`' reader sleeps at each piece, keeps it, then answers no values, through both shells (the review's second). With either shell's fix taken out the script's second and third checks go red, the client reading the other's bytes; with neither, both shells answer 500 alike and the contract stays green (measured).

Measured on the step's tree (2026-10-03, Darwin arm64): `make test` green, forty-seven suites, 1,644 expected passes (1,643 + 1), every pin ok.

Watched to fail (m7-mutations.md, the M7 exit): M7Z-1 and M7Z-2, each shell's fix taken out, and M7.3's thirty-three again on the step's tree, M7C-6 and M7F-3 re-cut for the step's text: thirty-five, each loading, each reddening a suite but M7F-10, M7.3's scope statement. Every check the step added or changed is reddened by one, 30 of 30: the shell suite's new check (M7Z-1 among six); and, `slept` changed under them, the contract's nine waiting scripts' three checks each, the order row and the fake-only close row, `/read-sleeps`' second and third by M7Z-1 and M7Z-2 among others.

Size: 4 inserted lines of `src/` and 2 deleted; 33 inserted lines of tests and 12 deleted.

NEXT: the second step, the exit's checks and records, stacked on this one.

M7 EXIT, SECOND STEP: R3's row first, and an idle connection carries no coroutine (feat/m7-exit).
- `tests/test-scheduler.sps`: R3's row runs first, and the header says why: a coroutine that returns normally breaks every drain after it, which since M7.2 comes at the first coroutine that raises, or parks and ends. Under M7S-B, R3's own, R3's row reads Chez's refusal, "attempt to invoke shot one-shot continuation", and the suite raises after it, as at M7.1.
- `tests/test-shell.sps`: `/noted`, a handler that sleeps, looks localhost up and meets a deadline of 0 ms, its reader's piece and end each sleeping and its producer sleeping before each call, each coroutine it runs on noted in a weak pair: once it is answered and its connection is idle, a full collection leaves none of them. The weak-pair instrument is the suite's own, calibrated.
- `.plans/research/spike/m7-exit-budget.sps`, new, with its runs, and two runs each of `m5-exit-budget.sps` on the tree before M7 and on M7's, in `out/`.
- Records: plan §14's M7 exit note; design §5.2's, §5.3's and §7.5's notes; the research README; the README's status; `docs/handlers.org`: once a waiting handler has answered, its connection holds no more than any other.

Measured on the finished tree (2026-10-03, Darwin arm64): `make test` green, forty-seven suites, 1,645 expected passes (1,644 + 1), every pin ok. The shell suite took 4.33 to 4.35 s with both new checks, main's 4.25 to 4.30 (three runs each, alternating). On Linux, in Docker's `chez-libuv-valgrind:10.4.1` image (698eba6; Linux 6.12.76-linuxkit aarch64, Chez 10.4.1, libuv 1.44.2), from a copy of the tree made with `COPYFILE_DISABLE=1`, curl, ab and python3 installed: `make test`, less its submodule and pin checks, forty-seven suites, 1,645 expected passes; the scheduler, shell and contract suites green three more times each; and the budget spike once, its 48 holds clean, none of 626,400 coroutines in the heap, a connection holding 1,917 to 1,929 B after waiting and 1,794 to 1,967 B after answers at once, a parked coroutine 3,644 B.

Watched to fail (m7-mutations.md, the M7 exit): sixty-nine mutants on the finished tree, each loading: the eighteen of R1–R5 again, the scheduler suite's other fourteen, M7H-6 and M7X-1 for the idle check, and the first step's thirty-five. Each reddens a check but three: M7B-6 and M7F-10, the scope statements of M7.1 and M7.3, and M7X-1, a scheduler keeping a continuation already used, which holds no frame. Every check the steps added or changed, and every row of the scheduler suite, is reddened by one, 60 of 60: R3's by M7S-B, R3's own; the idle check by M7H-6, a coroutine kept in the heap's slot, which no other check in the shell suite sees. M7W-1's contract raised once, in the run before the review's fixes (exit 2, after 71 checks), and in none since, nine runs by hand and the run after the fixes passing all 187 checks: its red is the waits and shell suites'.

Size, against the first step: 80 inserted lines of tests and 24 deleted (the scheduler suite's 30 and 23, R3's row moved and the header; the shell suite's 50 and 1); the spike, 161 lines, and its runs.

M7 EXIT BUILT, the two steps proved each on its own tree (2026-10-03):
- the first, main at 3b1bb75 with its four files: `make test` green, forty-seven suites and 1,644 expected passes; its thirty-five mutants there, 30 of 30 checks;
- the second, the finished tree: forty-seven suites and 1,645, on Darwin and on Linux in Docker; sixty-nine mutants, 60 of 60 checks.

No file under `src/` changes but the libuv shell, in the first step.

NEXT: the owner's word on how it ships: two stacked PRs, the fix below the exit, as decided; then the closing ritual on "do closing ritual", and M8 when the owner asks.

MERGED to main on 2026-10-03, on the owner's "do closing ritual": **the M7 exit, as two stacked PRs.**
- **#104, a waiting handler's reader may answer a piece with no values,** as 0bcb998. Its squash tree (c918d68) is the tested tip's, ecb90c9's, and its parent is 3b1bb75. It merged first and kept its branch, since #105 was based on it.
- **#105, R3's row first, and an idle connection carries no coroutine,** as d3ad473. It was retargeted to main and rebased from #104's tip, ecb90c9. The rebased tip, 6f32f28, has the tested tree (0ce2ff5, 3214bb7's), and so does the squash, whose parent is 0bcb998.
- **CI.** Each merged on `linux` SUCCESS at its head: #104 on ecb90c9 (run 37123999546); #105 on 6f32f28 (run 37124260922). Each log holds its step's count: forty-seven suites, 1,644 and 1,645 expected passes.
- **Branches.** Both deleted, local and remote, and refs pruned. No PR is open.

`make test` green on main: forty-seven suites, 1,645 expected passes, every pin ok.

DONE and merged (0bcb998, PR #104; d3ad473, PR #105): **the M7 exit. M7 COMPLETE.**
- Each of R1–R5 has a mutation that goes red on the merged tree; R3's again, its row now first.
- The budget spike, run again: an idle connection carries no coroutine, and holds 32 B more than before M7, three fields of its record, which hold nothing while it is idle; the shell suite checks that it holds none of the coroutines its handler, reader and producer ran on.
- Found and fixed on the way, as its own PR: a waiting reader's piece that answered no values failed its handler.
- Decided by form: R3's row first; the fix as its own PR; the check in `make test`; review, then two stacked PRs. A /code-review high found four, in tests; three were fixed, and the fourth, R3's row held first by its place alone, is noted.

NEXT: M8 (plan §14), shutdown, hand-off, black-box and release, when the owner asks.

