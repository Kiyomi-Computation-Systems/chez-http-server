# Refutation pass: gap-chez-httparse.md

Target document: `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/research/gap-chez-httparse.md`

Method: for every item's evidence, every `file:line` citation was opened directly at
that line range in the actual repo on disk (`/Users/yuzu/github/chez-httparse`,
`/Users/yuzu/github/byte-machine`, `/Users/yuzu/github/chez-http-server`) with `sed
-n`/`grep -n`/`awk`, and every claim settled by running a program was re-run verbatim
from the preserved probe scripts at
`/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/probe/`.
Chez: 10.4.1 on PATH. All six probes (`flags-probe.sps`, `keepalive-probe.sps`,
`eof-finish-probe.sps`, `connect-trailer-probe.sps`, `pause-resume-probe.sps`,
`pri-upgrade-probe.sps`) and `test/common/allocation-tests.sps` were re-run with:

```
CHEZSCHEMELIBDIRS=/Users/yuzu/github/chez-httparse/src:/Users/yuzu/github/chez-httparse/vendor/byte-machine/src \
  chez --program <script>.sps
```

(allocation-tests.sps additionally needs `:/Users/yuzu/github/chez-httparse/test/support/harness`
on `CHEZSCHEMELIBDIRS`, exactly as the original document's own command line shows).

**Overall finding: the original gap analysis is unusually well-sourced.** Every
source-file line range checked pointed at real code saying what was claimed, all six
probe outputs reproduced byte-for-byte (including offsets, byte counts, and event
orderings), and the allocation numbers reproduced exactly on a second run. Three
genuine defects were found, all narrow:

1. **Item 1** cites `docs/api.org:287` for "flags is printed in hex (`%x`)". That text
   does not exist in `docs/api.org` at all — line 287 and its surrounding context is
   the *Lifecycle* section (`parser-reset!`/`parser-resume!`/`parser-finish!`), and a
   full-file `grep -n "hex\|%x" docs/api.org` returns **zero** matches. The `%x`
   format string is real, but it lives in the *test harness*, not the docs:
   `test/support/harness/httparse/test/adapter.sls:165-167`. The underlying numeric
   claim (flags=22 in a trace is hex, i.e. 34 decimal) is still correct — independently
   confirmed by the live `flags-probe.sps` run below, which shows the Content-Length +
   Connection:close case landing on flags value `34` — but the citation supporting it
   is fabricated.
2. **Item 4/5** cites `docs/api.org:67-69` as documenting "the distinction between a
   callback-requested pause and the machine's own pause." That text (quoted verbatim
   below) says only that `'paused` means "a callback returned `callback-pause`"; it
   never mentions a second, machine-triggered pause case at all, so it does not
   document any such distinction — if anything, read literally it implies pause is
   *always* callback-triggered. The actual distinction is real and correctly
   demonstrated by the probe and by `drive.sls:45-54` (also cited, and verified
   correct), just not by `docs/api.org:67-69`.
3. **Item 10** miscounts twice: it claims "41 message-grammar declarations
   (`src/httparse/grammar.sls:778-942`)" — the actual count in that exact range is
   **55** (verified two ways: `grep -c` and a full listing, reproduced below). It also
   claims "the generated 61-entry errs vector actually shipped in
   `src/generated/httparse-message.sls:4`" — the actual count is **63** (verified with
   a regex extraction of every `#(symbol "reason")` entry on that line, reproduced
   below). Both numbers are off; the substantive claim (errors are well-specified,
   llhttp-sourced, and the `invalid-transfer-encoding` granularity gap is real) still
   holds — `request-invalid-te` really is at `grammar.sls:880-881` exactly, and
   `parser-error-domain` really is at `runtime.sls:302-303` exactly — but the specific
   counts in the evidence are wrong and should be corrected to 55 and 63.
4. **Item 11** cites `docs/api.org:142-146` as "the doc's own worked example"
   showing `POST → 3`, `PATCH → 28`. That range is about URL `userinfo`/`@`
   parsing and has nothing to do with method numbers. A full-file
   `grep -n "PATCH\|method=28\|method=3\b" docs/api.org` returns **zero** matches, and
   `grep -n "method" docs/api.org` shows the only three mentions of "method" in the
   entire file are the callback-list row, the `type`-mode prose, and the
   `parser-field-ref` table row (line 274, itself correctly cited). There is no worked
   method-number example anywhere in `docs/api.org`. This citation is fabricated; the
   live citation for the same claim (`message-loop-tests.sps:150`, `method=28` for a
   PATCH fixture) is accurate and independently sufficient to support the underlying
   fact.
5. Item 1's shown reproduction command, `rg -n "..." src/ -tsls`, does not actually run
   as shown on this machine (`ripgrep 15.1.0`): `-tsls` is not a recognized file type
   (`rg: unrecognized file type: sls`), so the command would exit with an error, not
   print `(no matches)`. This is a reproducibility defect in the write-up, not a
   substantive error — re-running the search correctly (`rg -n "..." src/ -g '*.sls'`)
   does return zero matches, so the underlying claim (no keep-alive-related export
   exists) is still correct.

None of these five issues change any item's present/partial/missing/unclear verdict.
Every verdict in the original document is confirmed correct by direct source
inspection and, where the item made a runnable claim, by re-running the exact probe.

---

## Item 1 — keep-alive decision (verdict: **partial** — CONFIRMED)

All grammar citations check out at the exact lines given:

```
$ sed -n '2436,2436p;2445,2445p;2461,2461p;2477,2477p;2485,2485p;2493,2493p;2500,2500p;2502,2502p;2511,2511p;2519,2519p;2528,2528p;2430,2430p;2432,2432p' src/httparse/grammar.sls
2436: ;; --- what a message leaves behind ----------------------------------------
2445: ;; `should_keep_alive` FOR A REQUEST is the version test and one flag:
2461: ;; resetting, and not inside either arm.
2477: (make-field-branch-node 'after-message 'nonzero (list 'http-major)
2485: (needs-eof-nodes "amc-eof" 'amc-close 'amc-keep-alive)
2493: (make-field-action-node 'amc-keep-alive 'store (list 'finish FINISH-SAFE)
2500:                         'start #f #f)
2502: (make-field-action-node 'amc-close 'store (list 'finish FINISH-SAFE)
2511: (make-field-action-node 'closed-clear-flags 'store (list 'flags 0)
2519: (make-byte-dispatch-node 'closed
2528:               'closed 'e-data-after-close)
2430: (ev 'message-complete-pause 'on-message-complete 'upgrade-pause)
2432: (ev 'message-complete 'on-message-complete 'after-message-upgrade)
```

Every one of these is exactly what the document quotes. The algorithm comment
(2445-2461) reads verbatim as quoted. The flag-bit table is exactly right:

```
$ grep -n "define F-" src/httparse/grammar.sls
301:  (define F-CONNECTION-KEEP-ALIVE 1)
302:  (define F-CONNECTION-CLOSE 2)
303:  (define F-CONNECTION-UPGRADE 4)
304:  (define F-CHUNKED 8)
305:  (define F-UPGRADE 16)
306:  (define F-CONTENT-LENGTH 32)
311:  (define F-TRAILING 128)
318:  (define F-SKIP-BODY 64)
319:  (define F-TRANSFER-ENCODING 512)
```

matching the document's table (values 1/2/4/8/16/32/64/128, plus 512 for
F-TRANSFER-ENCODING) at exactly lines 301-319 as cited. `src/httparse/grammar.sls:1-5`
is exactly the "BUILD TIME ONLY... never loaded by a running parser" header quoted.

`docs/api.org:101-120` and `docs/api.org:54-58` are exactly the 25-callback table and
the 5-field result table, respectively, matching what's quoted (confirmed via
`grep -n "Reading the result\|The full list\|twenty-five, all required"` → lines
52/101/119, and the table rows at 54 and 58).

`byte-machine/src/byte-machine/runtime.sls:16-31` genuinely exports
`parser-state-name`, and its "must name a source node, not a generated internal
continuation" comment is real, at line 27 (the export list comment) and again in prose
at line 592 (`;; Requires the SOURCE node name, "not a generated internal
continuation"...`) — the document's citation of `runtime.sls:592-594` for this is
correct.

**Live reproduction — `flags-probe.sps`:**

```
$ CHEZSCHEMELIBDIRS=/Users/yuzu/github/chez-httparse/src:/Users/yuzu/github/chez-httparse/vendor/byte-machine/src \
    chez --program flags-probe.sps
=== connection.md#9 fixture (Content-Length + Connection: close) ===
(status error flags-at-headers-complete 34 flags-at-message-complete 34 consumed 138 stream-offset 138 error (closed-connection "Data after `Connection: close`" 138))
=== plain Connection: close, no content-length ===
(status need-input flags-at-headers-complete 2 flags-at-message-complete 2 consumed 37 stream-offset 37 error #f)
=== HTTP/1.1 default keep-alive (no Connection header) ===
(status need-input flags-at-headers-complete 0 flags-at-message-complete 0 consumed 18 stream-offset 18 error #f)
=== HTTP/1.0 default (no Connection header) ===
(status need-input flags-at-headers-complete 0 flags-at-message-complete 0 consumed 18 stream-offset 18 error #f)
=== HTTP/1.0 + Connection: keep-alive ===
(status need-input flags-at-headers-complete 1 flags-at-message-complete 1 consumed 42 stream-offset 42 error #f)
```

Matches the document's quoted excerpt exactly (`flags-at-headers-complete 34
flags-at-message-complete 34 ... consumed 138`).

**Live reproduction — `keepalive-probe.sps` (state-name half):**

```
--- state-name after message-complete, by keep-alive decision ---
HTTP/1.1, no Connection header (default keep-alive) => status=need-input state-name=start
HTTP/1.1, Connection: close => status=need-input state-name=closed
HTTP/1.0, no Connection header (default close) => status=need-input state-name=closed
HTTP/1.0, Connection: keep-alive => status=need-input state-name=start
```

Matches exactly.

**Discrepancy found (see summary #1):** `docs/api.org:287` does not say flags are
printed in hex. `grep -n "hex\|%x" docs/api.org` returns nothing; line 287 is inside
the *Lifecycle* section. The `%x` format string genuinely exists, but at
`test/support/harness/httparse/test/adapter.sls:165-167`:

```
165:  ;;   "headers complete method=%d v=%d/%d flags=%x content_length=%llu"
166:  ;;   "headers complete status=%d v=%d/%d flags=%x content_length=%llu"
167:  ;; chosen by `s->type`, and identical after their first field. `%x` IS
```

The "flags=22" occurrences the document points at are real
(`message-loop-tests.sps:204` — exact; `message-loop-tests.sps:175`, not 176 — an
off-by-one, the comment explaining it spans 175-176 so this is trivial) and the hex
interpretation (0x22 = 34 decimal) is independently confirmed by the live probe above,
so only the specific `docs/api.org:287` citation is wrong, not the underlying claim.

**Discrepancy found (see summary #5):** the shown reproduction of the "no exports"
search does not run as shown on this machine:

```
$ rg -n "define.*keep-alive|should-keep-alive|export.*keep" src/ -tsls
rg: unrecognized file type: sls
```

(ripgrep 15.1.0 has no built-in `sls` file type.) Re-run correctly with a glob:

```
$ rg -n "define.*keep-alive|should-keep-alive|export.*keep" src/ -g '*.sls'
(no output — confirms zero matches)
```

So the underlying claim ("no exported keep-alive procedure exists") is still true;
only the exact command transcript in the document is not reproducible as shown.

**Verdict check:** partial is correct. Both workarounds are real, both are verified
live above, and no exported single-call decision procedure exists anywhere in
`src/` (confirmed by the corrected `rg` search).

---

## Item 2 — body framing with no Content-Length/Transfer-Encoding (verdict: **partial** — CONFIRMED)

Request-side citation `grammar.sls:643-644`:

```
643:      (make-field-branch-node (nm "request") 'equal (list 'type TYPE-REQUEST)
644:                              no (nm "informational") #f)
```

Exact match — this is `needs-eof-nodes`'s first branch, hard-wiring "no" for every
request as claimed.

Response-side block, citation `grammar.sls:2130-2150`:

```
2130:       ;; --- a body the connection ends -----------------------------------------
...
2141:       (make-field-action-node 'body-eof 'store (list 'finish FINISH-SAFE-WITH-CB)
...
2146:       ;; Reached only if an embedder calls `parser-finish!`, which the corpus
...
2148:       ;; `finish` FIELD and does not end the parse.
2150:       (make-finish-node 'body-eof-stop #f)
```

All five line numbers land exactly on the quoted text, including the decision-0016
comment. `needs-eof-nodes "ahc-eof"` is confirmed at line 2120, inside the cited
2113-2120 range.

Fixture citation `test/common/response-framing-tests.sps:56-68` (`response/connection.md#4`):

```
54:  (lambda ()
55:    (harness-case "response/connection.md#4"
56:      (lambda ()
57:        (check-equal "trace"
58:                     (trace "HTTP/1.1 200 OK\r\n\r\nHTTP/1.1 200 OK")
...
68:                       "off=19 len=15 span[body]=\"HTTP/1.1 200 OK\""))))
```

Confirmed: the trace really does end at a `span[body]` line with no `message
complete` line, exactly as claimed.

**Live reproduction — `eof-finish-probe.sps`:**

```
feed headers: (status need-input state body-eof-consume)
feed body chunk 1: (status need-input state body-eof-consume message-complete-fired 0 body-so-far "hello ")
feed body chunk 2: (status need-input state body-eof-consume message-complete-fired 0 body-so-far "hello world")
now call parser-finish! (socket EOF): (status finished consumed 0 stream-offset 30 state body-eof-stop message-complete-fired 0 body-final "hello world")
calling parser-finish! AGAIN (already finished) -- lifecycle: finished
```

Byte-for-byte identical to the document's quoted transcript.

The negative check on `'finish` is exactly reproducible:

```
$ rg -n "'finish\b" src/httparse/grammar.sls | grep -v "FINISH-"
2506:      ;; `update('finish', FINISH.SAFE, lenientClose)` -- so a lenient parse
```

One hit, and it is a comment (it survives the `grep -v "FINISH-"` filter only because
it says `FINISH.SAFE` with a period, not a hyphen) — exactly as the document says.

`byte-machine/src/byte-machine/runtime.sls:1421-1597`/`1453-1456` genuinely is
`parser-finish-op!`, and its `finish` case (confirmed at the lines shown) really does
just set lifecycle to `'finished` and return, with no callback dispatch — confirmed by
direct inspection of the case-loop body.

`docs/api.org:285-308` is genuinely the *Lifecycle* section, and it genuinely never
mentions the EOF-body/no-message-complete asymmetry; `docs/api.org:279-283` genuinely
only discusses `content-length` counting down. Both citations check out.

**Verdict check:** partial is correct — implementation matches, doc gap is real, and
the completion-signal asymmetry (`parser-finish!` returning `'finished`, never
`on-message-complete`, for this one framing) is real and reproduced live.

---

## Item 3 — data-after-close error (verdict: **present** — CONFIRMED)

```
927:           (make-error-declaration 'data-after-close 'closed-connection
928:                                   "Data after `Connection: close`" #f)
```

Exact match. Reached-from citation `grammar.sls:2519-2528`:

```
2519:      (make-byte-dispatch-node 'closed
...
2528:                    'closed 'e-data-after-close)
```

Exact match, including the lenient-fork call. Lenient-flag citation
`src/httparse/modes.sls:38-49`:

```
38:  (define httparse-lenient-flag-bits
39:    '((headers                      1)
40:      (chunked-length               2)
41:      (keep-alive                   4)
42:      (transfer-encoding            8)
43:      (version                     16)
44:      (data-after-close            32)
...
49:      (header-value-relaxed      1024)))
```

`data-after-close` really is bit 32, at exactly line 44 (inside the cited 38-49
block).

**Live reproduction — `keepalive-probe.sps` (closed-connection case):**

```
close, then a second GET follows anyway => (status error consumed 39 len 57 error closed-connection)
```

Identical to the document's transcript (`consumed 39, len 57`).

`request/connection.md#9` fixture is real, at `message-loop-tests.sps:172-180`
(harness-case starts at 172, "flags=22 is CONTENT_LENGTH and CONNECTION_CLOSE
together" comment at 175-176).

**Verdict check:** present is correct.

---

## Item 4 & 5 — pipelining, pause/resume mechanics (verdict: **present** — CONFIRMED)

`test/common/message-loop-tests.sps:92-151` is exactly the `request/pipelining.md#1`
harness-case (`grep -n "request/pipelining.md#1"` → line 92, matching the cited
start), and its trace really does show `"off=44 message complete"` immediately
followed by `"off=46 reset"` then `"off=46 message begin"` inside one `parser-feed!`
call (`message-loop-tests.sps:42`, confirmed exact:
`(let ((res (parser-feed! p bv 0 (bytevector-length bv))))`).

**Live reproduction — `keepalive-probe.sps` (pipelining half):**

```
keep-alive, two GETs => (status need-input consumed 38 len 38 error #f)
```

Matches.

**Live reproduction — `pause-resume-probe.sps`:**

```
feed whole buffer, pause requested after message 1 => (status paused consumed 19 next 19 stream-offset 19 pause-is-machine-pause? #f mc-count 1)
resume ack: feed-ready
feed remainder from parser-result-next => (status need-input consumed 38 stream-offset 57 mc-count 3)
```

Byte-for-byte identical to the document's transcript.

`byte-machine/src/byte-machine/runtime.sls:1604-1619` is exactly `parser-resume!`
(confirmed: `define (parser-resume! parser)` at line 1604), and it only flips
lifecycle with no callback, as claimed.

`test/support/harness/httparse/test/drive.sls:70-78` is exactly `drive-feed!`,
re-feeding from `(parser-result-next res)` as quoted — confirmed verbatim.

`byte-machine/src/byte-machine/runtime.sls:18` genuinely exports `parser-result-next`
in the library's export clause (`parser-result? parser-result-status parser-result-next
...`), and `docs/api.org:54-58`'s "Reading the result" table genuinely omits it
(the table lists only status/consumed/stream-offset/error/pause) — the documented-gap
claim is correct.

`pausing-tests.sps:81-90` genuinely covers `on_message_begin` pausing at offset 0;
`pausing-tests.sps:108-129` covers `on_header_field_complete` mid-message pause and
resume (verified: the header-field case runs from line 114 to 129, matching the cited
"114-129"); `pausing-tests.sps:130-150` covers `on_chunk_complete` re-pausing on every
firing — confirmed verbatim ("an armed callback that fires twice pauses twice... Two
chunks, two pauses").

**Discrepancy found (see summary #2):** `docs/api.org:67-69` is real text:

```
67: - ='paused= — a callback returned =callback-pause=. Resume with
68:   =parser-resume!=. (Not exercised by v0.1's corpus coverage — see
69:   [[file:conformance.org][conformance.org]].)
```

but this text describes only the callback-requested case; it never contrasts it with
the machine's own upgrade/CONNECT pause, so it does not "document" that distinction as
claimed. The distinction itself is real (confirmed by the probe's
`pause-is-machine-pause? #f` field and by `drive.sls:45-54`'s
`drive-requested-pause?`, both correctly cited and verified), just not by this
particular `docs/api.org` line range.

**Verdict check:** present is correct for both items; the
`parser-result-next`-undocumented gap is real and correctly demonstrated.

---

## Item 6 — skip-body (verdict: **present** for the mainstream case — CONFIRMED)

```
1970:      (make-callback-node 'headers-complete 'on-headers-complete 'after-headers
1971:                          (list (list 'skip-body 'headers-complete-skip-body))
1972:                          'after-headers #f)
1973:      (make-field-action-node 'headers-complete-skip-body 'set-mask
1974:                              (list 'flags F-SKIP-BODY) 'after-headers #f #f)
```

Matches the cited 1966-1974 block (1966-1969 is the leading comment, verified
present). `ahc-upgrade-skip-body` is confirmed at exactly line 1996, and the "NO
VENDORED FIXTURE ARMS SKIP-BODY ON AN UPGRADE... the corpus cannot vouch for it"
comment is confirmed at line 1993 (part of a 1990-1995 comment block).

**Live reproduction — `keepalive-probe.sps` (skip-body half):**

```
HEAD-response skip-body => (status need-input body-bytes-seen 0 consumed 85 len 85)
```

Matches exactly.

**Verdict check:** present is correct; the CONNECT+skip-body combination is correctly
flagged as unprobed and upstream-disclaimed, not asserted as broken or working.

---

## Item 7 — upgrade/CONNECT pause vs. h2c-preface error (verdict: **partial** — CONFIRMED, this is the sharpest real trap in the library)

Every one of the seven grammar line citations checks out exactly:

```
941:           (make-error-declaration 'upgrade-paused 'paused-upgrade
942:                                   "Pause on CONNECT/Upgrade" #f))
...
2062:      (make-pause-node 'upgrade-pause 'after-message 'upgrade-paused #f)
...
2433:      (make-field-branch-node 'after-message-upgrade 'nonzero (list 'upgrade)
2434:                              'upgrade-pause 'after-message #f)
...
1942:      (make-field-branch-node 'before-headers-complete 'mask-all
1943:                              (list 'flags (+ F-UPGRADE F-CONNECTION-UPGRADE))
1944:                              'bhc-upgrade-request 'bhc-check-connect #f)
1945:      (make-field-branch-node 'bhc-upgrade-request 'equal (list 'type TYPE-REQUEST)
1946:                              'bhc-upgrade-yes 'bhc-switching #f)
...
1954:      (make-field-branch-node 'bhc-switching 'equal (list 'status-code 101)
1955:                              'bhc-upgrade-yes 'bhc-upgrade-no #f)
...
1958:      (make-field-branch-node 'bhc-check-connect 'equal
1959:                              (list 'method (method-number "CONNECT"))
1960:                              'bhc-upgrade-yes 'bhc-upgrade-no #f)
...
1961:      (make-field-action-node 'bhc-upgrade-yes 'store (list 'upgrade 1)
1962:                              'headers-complete #f #f)
```

`response-framing-tests.sps:300-320` (`response/connection.md#12`) is confirmed: a 200
with `Connection: upgrade`/`Upgrade: h2c` and no framing header falls straight through
to the read-to-EOF body path with no pause and no message-complete
(`"off=54 len=4 span[body]=\"body\""` is the trace's last line).

`grammar.sls:929-933` (`pri-upgrade` declaration and its own warning comment) is
confirmed exactly:

```
929:           ;; PRI's HTTP/2 preface. llhttp calls it a pause in the reason and
930:           ;; implements it as an ERROR, which is why this one has a number to
931:           ;; rename and the CONNECT/Upgrade pause does not.
932:           (make-error-declaration 'pri-upgrade 'paused-h2-upgrade
933:                                   "Pause on PRI/Upgrade" #f)
```

**Live reproduction — `connect-trailer-probe.sps` (CONNECT-pause half):**

```
--- CONNECT pause and unconsumed tail ---
CONNECT => (status paused consumed 55 total-len 68 leftover "TLSHELLOBYTES" pause-reason (paused-upgrade "Pause on CONNECT/Upgrade"))
```

Matches exactly (consumed=55, leftover="TLSHELLOBYTES").

**Live reproduction — `pri-upgrade-probe.sps`:**

```
PRI/Upgrade (h2c prior-knowledge preface) => (status error consumed 24 error-slot (paused-h2-upgrade "Pause on PRI/Upgrade" 24) pause-slot #f)
```

Matches exactly — `status='error`, not `'paused`, with `parser-result-pause` staying
`#f`, confirming the channel-split trap is real and not a misreading.

**Verdict check:** partial is correct, and this is a genuine, well-demonstrated
correctness trap for any connection layer that dispatches on `(eq? status 'paused)`
alone.

---

## Item 8 — header limits (verdict: **missing** (as an absence, working as intended) — CONFIRMED)

No counting/limit logic for header bytes exists anywhere in `grammar.sls` (confirmed
by the same live probe below and by inspection — there is no `content-length`-style
field or comparison node for header bytes anywhere in the file).

**Live reproduction — `connect-trailer-probe.sps` (huge-header half):**

```
--- 200000-byte header value, no configured limit ---
huge header => (status need-input header-value-bytes-seen 200000)
```

Matches exactly.

Architecture-doc citation `.plans/chez-http-server-architecture.md:413-414`:

```
413:- maximum request sizes,
414:- maximum header sizes,
```

Exact match, both lines present verbatim in the connection-layer responsibility list.

**Verdict check:** missing-as-absence is correct and appropriately framed as
by-design, not a bug.

---

## Item 9 — chunked bodies and trailers (verdict: **present** — CONFIRMED)

```
2225:      (ev 'chunk-size-header 'on-chunk-header 'chunk-size-test)
```

Exact match for the `on-chunk-header` citation. The body-data-span block
(`grammar.sls:2233-2238`) is confirmed to be the comment-plus-span-start block
immediately preceding `chunk-data-open`/`chunk-data-consume` (span-start line 2237,
consume line 2238) — the same span/consume machinery a fixed body uses, exactly as
claimed. `F-TRAILING`/`chunk-trailing-flag` (`grammar.sls:2230-2231`) is confirmed at
line 2231 (`(make-field-action-node 'chunk-trailing-flag 'set-mask (list 'flags
F-TRAILING) ...)`). `check-trailing` (`grammar.sls:1924-1925`) and
`trailer-chunk-complete` (`grammar.sls:1930`) are both confirmed exactly:

```
1924:      (make-field-branch-node 'check-trailing 'mask-any (list 'flags F-TRAILING)
1925:                              'trailer-chunk-complete 'before-headers-complete #f)
...
1930:      (ev 'trailer-chunk-complete 'on-chunk-complete 'message-complete)
```

Confirming trailers route to `on-chunk-complete`, not a second `on-headers-complete`,
exactly as claimed.

**Live reproduction — `connect-trailer-probe.sps` (trailers half):**

```
--- chunked trailers ---
trailers => status=need-input
message-begin
(header-field "Transfer-Encoding")
header-field-complete
(header-value "chunked")
header-value-complete
headers-complete
chunk-header
(body "hello")
chunk-complete
chunk-header
(header-field "X-Trailer")
header-field-complete
(header-value "value")
header-value-complete
(header-field "X-Trailer2")
header-field-complete
(header-value "v2")
header-value-complete
chunk-complete
message-complete
```

Matches the document's quoted event sequence exactly, including "chunk-complete, NOT
headers-complete again."

**Verdict check:** present is correct, and the trailers-indistinguishable-from-headers
consequence is correctly derived from the callback shape.

---

## Item 10 — error codes and HTTP-status mapping (verdict: **present** — CONFIRMED, with two numeric corrections)

`request-invalid-te` is confirmed exactly:

```
880:           (make-error-declaration 'request-invalid-te 'invalid-transfer-encoding
881:                                   "Request has invalid `Transfer-Encoding`" #f)
```

`byte-machine/src/byte-machine/runtime.sls:302-303` is confirmed exactly as
`parser-error-domain`'s definition (comment at 302, `(define (parser-error-domain e)
(vector-ref e 1))` at 303). `runtime.sls:287-291` is confirmed exactly as
`byte-machine-make-callback-error/v1`'s definition. `docs/api.org:72-80` (decision
0013, "the code/reason pair is llhttp's, deliberately... so a caller can switch on the
symbol and log the text") is confirmed verbatim.

**Numeric correction #1.** The document claims "41 message-grammar declarations
(`src/httparse/grammar.sls:778-942`)". A direct count in exactly that range:

```
$ awk 'NR>=778 && NR<=942' src/httparse/grammar.sls | grep -c "make-error-declaration"
55
```

None of the 55 hits are inside comments (verified: `grep -c "^\s*;;"` over the same
filtered set returns 0). A full listing (55 lines, `'eof` through `'upgrade-paused`)
was produced and manually spot-checked; the count is genuinely 55, not 41. This is
also exactly the whole file's count (`grep -c "make-error-declaration"
src/httparse/grammar.sls` → 55), confirming every message-grammar error declaration in
the file falls inside the cited 778-942 range — so the *range* citation is fine, only
the *count* inside it is wrong.

**Numeric correction #2.** The document claims "the generated 61-entry errs vector
actually shipped in `src/generated/httparse-message.sls:4`". Extracting every
`#(symbol "reason")` entry from that line with a regex:

```
$ python3 -c "
import re
with open('/tmp/errsline.txt') as f:   # sed -n '4p' src/generated/httparse-message.sls
    content = f.read()
matches = re.findall(r'#\(([a-zA-Z0-9_-]+) ', content)
print('count:', len(matches))
"
count: 63
```

(Confirmed the extracted line is exactly the `errs` vector definition and nothing
else — it starts with `(define errs (quote #(#(unexpected-eof ...` and ends cleanly
with `...\"Invalid char in url fragment start\"))))`, no other top-level forms on that
line.) The actual count is 63, not 61.

Neither miscount changes the item's substance: the error-code inventory is real,
llhttp-sourced, and the `invalid-transfer-encoding` conflation (400 vs. 501 for
`request-invalid-te`) genuinely requires reason-string matching as claimed, since
`request-invalid-te` and its 400-mappable siblings (e.g. `bad-te-value` at line 878)
share the same `parser-error-code` symbol (`invalid-transfer-encoding`) and are
distinguished only by reason text.

**Verdict check:** present is correct; recommend correcting "41" → "55" and "61" →
"63" if this evidence is carried forward into chez-http-server's own design docs.

---

## Item 11 — method name/number table (verdict: **partial** — CONFIRMED, with one fabricated citation)

```
100:(library (httparse grammar)
101:  (export make-message-machine
102:          httparse-tchar-bytes httparse-header-bytes
103:          httparse-method-names httparse-method-numbers
104:          httparse-http-methods httparse-rtsp-methods httparse-ice-methods
105:          method-name->identifier)
106:  (import (rnrs) (byte-machine graph) (httparse modes) (httparse url-grammar))
```

Confirms both the export citation (100-105) and the `(byte-machine graph)` import
citation (106) exactly. The method-name/number tables are confirmed at
`grammar.sls:155-186` — 47 names counted programmatically (Python list count = 47),
matching the document's "47 names" claim exactly, and `PATCH → 28` /
`POST → 3` are both present in `httparse-method-numbers`
(`("PATCH" . 28)`, `("POST" . 3)`). `method-number-name` is confirmed at exactly line
267 (`(define (method-number-name name) ...)`), unexported, matching the "builds a
node-name symbol... and is not exported" claim. `docs/api.org:274` is confirmed
exactly as the `'method` row in the `parser-field-ref` table
(`| ='method=         | llhttp's method number, not an index into any list here |`).
`modes.sls:1-15` is confirmed exactly as the "THIS LIBRARY IS PURE AND DEPENDS ON
NOTHING" header quoted.

**Fabricated citation found (see summary #4).** The document says the `POST → 3,
PATCH → 28` claim is "confirmed both from the doc's own worked example,
`docs/api.org:142-146`, and live in `message-loop-tests.sps:150`." Checking
`docs/api.org:142-146` directly:

```
$ sed -n '140,148p' docs/api.org
is open when the refusal happens, and an error abandons an open span rather
than flushing it.

A target with *two userinfo =@= that are not adjacent* is accepted, because
llhttp accepts it: =http://a@b@c/p= is a host of =a@b@c=. Only =@@= is
=Double @ in url=. This parser refused the second =@= wherever it fell until
the live differential said otherwise.

If you want the target broken into schema, host, path, query and fragment,
```

This is entirely about URL `userinfo`/`@`-sign parsing. There is no method-number
worked example anywhere in the file:

```
$ grep -n "PATCH\|method=28\|method=3\b" docs/api.org
(no output)
$ grep -n "method" docs/api.org
105:| =on-method-data=                 | =on-method-complete=                 |
171:HTTP does not say which is coming: a request begins with a method and a
274:| ='method=         | llhttp's method number, not an index into any list here |
```

Three mentions total, none a worked numeric example. The `docs/api.org:142-146`
citation is fabricated. The other half of the same claim,
`message-loop-tests.sps:150`, is accurate:

```
$ awk 'NR==150' test/common/message-loop-tests.sps
                       "off=134 headers complete method=28 v=1/1 flags=20 content_length=5"
```

— so the underlying fact (method numbers are llhttp's own, PATCH is 28) is true and
independently supported by a citation that does check out; only the docs.org half of
the citation pair is invented.

**Verdict check:** partial is correct — the build-time-only layering problem for
`(httparse grammar)` is real and well-demonstrated — but the `docs/api.org:142-146`
citation should be struck or corrected; it does not support the claim it is attached
to.

---

## Item 12 — allocation cost (verdict: **present** — CONFIRMED)

**Live reproduction — `test/common/allocation-tests.sps`:**

```
$ CHEZSCHEMELIBDIRS=/Users/yuzu/github/chez-httparse/src:/Users/yuzu/github/chez-httparse/vendor/byte-machine/src:/Users/yuzu/github/chez-httparse/test/support/harness \
    chez --program test/common/allocation-tests.sps
httparse-harness: suite=property.allocation
httparse-harness: runtime=chez version=10.4.1 machine=tarm64osx mode=unknown os=darwin architecture=arm64
httparse-allocation: unknown whole-buffer small=6112B large=6160B ratio=100%
httparse-allocation: per-feed 50B message=404B  10043B message=384B
httparse-harness: summary suite=property.allocation runtime=chez mode=unknown cases=5 failed-cases=0 checks=9 failures=0 cleanup-failures=0 skipped=0 errors=0 status=0
```

Every number (6112B, 6160B, 100% ratio, 404B/384B per-feed) is identical to the
document's quoted transcript, on a fresh run.

`byte-machine/src/byte-machine/runtime.sls:218-223` is confirmed exactly as the
`parser-result` record constructor, and the vector really does have 7 elements
(`(vector parser-result-tag status next consumed stream-offset error pause)`),
matching the "7-element vector" claim.

**Verdict check:** present is correct, with genuinely reproduced live numbers.

---

## Item 13 — response-mode parser (verdict: **present** — CONFIRMED)

`docs/api.org:169-184` is confirmed to be the `** =type= — request or response`
section discussing the mode switch. `grammar.sls:2036-2045` is confirmed to be exactly
the five-status-code special-casing chain:

```
2036:      (make-field-branch-node 'ahc-continue 'equal (list 'status-code 100)
2037:                              'message-complete-done 'ahc-processing #f)
2038:      (make-field-branch-node 'ahc-processing 'equal (list 'status-code 102)
2039:                              'message-complete-done 'ahc-early-hints #f)
2040:      (make-field-branch-node 'ahc-early-hints 'equal (list 'status-code 103)
2041:                              'message-complete-done 'ahc-no-content #f)
2042:      (make-field-branch-node 'ahc-no-content 'equal (list 'status-code 204)
2043:                              'message-complete-done 'ahc-not-modified #f)
2044:      (make-field-branch-node 'ahc-not-modified 'equal (list 'status-code 304)
2045:                              'message-complete-done 'ahc-skip-body #f)
```

All five codes (100, 102, 103, 204, 304) are present exactly as claimed.
`response-framing-tests.sps:117-148` (`response/connection.md#15`) is confirmed: a 304
with `Content-Length: 10` produces `"off=49 message complete"` immediately followed by
`"off=51 reset"` and a second message beginning — i.e. it reads no body and restarts
cleanly, exactly as claimed.

**Verdict check:** present is correct; response mode is genuinely a first-class mode
of the same machine and its edge cases are exactly the ones already covered (and
verified above) in items 2, 6, 7 and 10.

---

## Summary table

| # | Need (short) | Citations verified | Status verdict |
|---|---|---|---|
| 1 | keep-alive decision | Yes, except one fabricated docs cite (`api.org:287`) and one non-reproducible `rg -tsls` command | partial — confirmed |
| 2 | EOF body framing | Yes, all | partial — confirmed |
| 3 | data-after-close | Yes, all | present — confirmed |
| 4/5 | pipelining + pause/resume | Yes, except one over-read docs cite (`api.org:67-69`) | present — confirmed |
| 6 | skip-body | Yes, all | present — confirmed |
| 7 | upgrade/CONNECT/h2c trap | Yes, all | partial — confirmed |
| 8 | header limits | Yes, all | missing (by design) — confirmed |
| 9 | chunked/trailers | Yes, all | present — confirmed |
| 10 | error codes/status mapping | Yes, except two miscounts (41→55, 61→63) | present — confirmed |
| 11 | method name/number table | Yes, except one fabricated docs cite (`api.org:142-146`) | partial — confirmed |
| 12 | allocation cost | Yes, all, live numbers reproduced exactly | present — confirmed |
| 13 | response mode | Yes, all | present — confirmed |
