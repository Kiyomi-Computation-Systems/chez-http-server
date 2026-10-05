# chez-http-server — ledger archive: M3, the response path

M3's entries, moved verbatim from `progress.md` on 2026-10-05 (its lines 1102–1758 at 64761cb). The mutation log is `m3-mutations.md`; the spine is `progress.md`.

---

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

