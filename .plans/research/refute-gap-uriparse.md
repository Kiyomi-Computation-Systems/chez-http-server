# Refutation pass: gap analysis of uriparse for chez-http-server

Reviewer role: REFUTER. Target document: `gap-uriparse.md`
(`/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/research/gap-uriparse.md`),
checked against the 13-item JSON gap list handed to me in the task. For every
item I opened the cited `file:line`(s) myself in `/Users/yuzu/github/uriparse`
(HEAD `3bfa51e1ccb0995bb29b43bd4a3df94ddeacd19b`, 2026-09-19 08:27:42 -0400,
clean working tree) and, where a claim was settled by running a program,
re-ran it verbatim from the probe/bench scripts left in this session's
scratchpad at `uriparse-probe/{probe,probe2,probe3,bench2,bench3,bench4}.sps`.

Overall verdict: **all 13 status labels (present/partial/missing) are
correct**, and every measured/empirical claim reproduced either bit-for-bit
(byte counts, parse outputs, error codes/offsets) or within ordinary
wall-clock jitter (nanosecond timings). I found **3 outright citation
errors** (a line range that does not contain the quoted text), **2 minor
off-by-one citation imprecisions**, and **1 minor factual error** (a
mislabeled byte count) — none of which change any status verdict or
consequence. Details per item below, then a consolidated list of the errors
found.

Commands were run from `/Users/yuzu/github/uriparse` unless noted:
```
chez --libdirs "src:vendor/byte-machine/src" --script <script>.sps
```

---

## 1. Parse origin-form (`/path?query`) — status **present**: AGREE

- `src/uri/grammar.sls:140-149` — read directly. Lines 140-142 are the
  `hier2` dispatch node (SLASH → `hier-slash1`, else `path-nc-open`); lines
  145-149 are `hier-slash1` (second SLASH → `auth-open`, i.e. authority;
  else → `say-rooted` → `path-open`). Confirmed.
- `src/uri/grammar.sls:159-166` — `path-open`/`path-scan`/`path-close-{q,f,end}`.
  Confirmed this is exactly the node sequence a leading-`/`-then-non-slash
  input reaches (traced by hand: `hier2`→`hier-slash1`→`say-rooted`(149)→
  `path-open`(159)).
- Consequence citation `grammar.sls:145-149` (the `//` ambiguity,
  `auth-open` on a second slash) — confirmed, same lines as above, line 146
  is literally `(kase (one SLASH) (adv 'auth-open))`.
- Measured (`uriparse-probe/probe.sps`), re-run:
  ```
  origin-form (relative-ref): mode=relative-ref input="/path/to/thing?q=1&a=2"
    scheme=<absent>  authority=<absent>  path="/path/to/thing"  query="q=1&a=2"  fragment=<absent>

  origin-form starting //  (ambiguity check): mode=relative-ref input="//evil.com/path"
    scheme=<absent>  authority="evil.com"  path="/path"  query=<absent>  fragment=<absent>
  ```
  Bit-for-bit identical to the original report. **Citations and status
  confirmed correct.**

## 2. Parse absolute-form (`http://host/path`) — status **present**: AGREE

- `src/uri/grammar.sls:125-131` — the `scheme` span (`uri-scheme-open` through
  `eat-colon`). Confirmed exact: `(make-span-start-node 'uri-scheme-open
  'scheme 'scheme-scan #f)` at 125 through `(eat 'eat-colon 'hier)` at 131.
- `src/uri/grammar.sls:145-156` — hier-slash1 → auth-open → auth-scan →
  auth-close, confirmed exact (same block checked in item 1/3).
- Measured, re-run:
  ```
  absolute-form (uri): mode=uri input="http://example.com:8080/path?q=1"
    scheme="http"  authority="example.com:8080"  path="/path"  query="q=1"  fragment=<absent>
  ```
  Identical to the original. **Citations and status confirmed correct.**

## 3. Parse authority-form (`CONNECT host:port`) — status **missing**: AGREE

- `src/uri/grammar.sls:171` — the `path-nc-first` COLON case,
  `(kase (one COLON) (rex 'e-scheme-forbidden))`. Confirmed exact, this is
  the line that fires `scheme-forbidden`.
- `src/uri/grammar.sls:145-156` (the `//`-prefix workaround path) — same
  block verified in item 2, confirmed correct.
- The "decision 0018's forward-only argument" gloss is not a line-citation
  but an analogy; I read `.plans/decisions/0018-path-absolute-slash-is-
  recovered-by-an-event.md` in full. 0018 is about the `//` vs `/`
  ambiguity specifically (not the scheme/authority colon case), but its
  underlying mechanism — byte-machine spans are forward-only, a mark can
  never move backward (0018 §Context items 1-3) — is exactly the mechanism
  that also makes `example.com:443` unrecoverable as authority-form without
  the `//`-prefix trick. The analogy is apt, not a citation error.
- Measured, re-run (all three modes plus both prefix workarounds), **all
  bit-for-bit identical** to the original, including the exact error offset:
  ```
  authority-form as 'uri (misparse expected): mode=uri input="example.com:443"
    scheme="example.com"  authority=<absent>  path="443"  query=<absent>  fragment=<absent>
  authority-form as 'relative-ref (error expected): mode=relative-ref input="example.com:443"
    ERROR code=scheme-forbidden offset=11
  authority-form as 'uri-reference (mode 3): mode=uri-reference input="example.com:443"
    scheme="example.com"  authority=<absent>  path="443"  query=<absent>  fragment=<absent>
  authority-form via //prefix hack: mode=relative-ref input="//example.com:443"
    scheme=<absent>  authority="example.com:443"  path=""  query=<absent>  fragment=<absent>
  authority-form IPv6 via //prefix hack: mode=relative-ref input="//[::1]:8080"
    scheme=<absent>  authority="[::1]:8080"  path=""  query=<absent>  fragment=<absent>
  ```
  **Citations and status confirmed correct.**

## 4. Parse asterisk-form (`OPTIONS *`) — status **partial**: AGREE

- `src/uri/charset.sls:45` for "`*` (byte 42) is a `sub-delim`" —
  **imprecise citation**: `sub-delim?`'s definition spans lines 44-46; line
  45 is `(or (fx=? b 33) (fx=? b 36) (fx=? b 38) (fx=? b 39) (fx=? b 40)
  (fx=? b 41)` and does **not** mention 42 — the actual `(fx=? b 42)` clause
  for byte 42 (`*`) is on **line 46**. The claim that `*` is a sub-delim is
  correct (`sub-delim?` does accept byte 42); only the specific line pointer
  is off by one.
- `src/uri/grammar.sls:160-175` for "`path-nc-first`/`path-scan` nodes" —
  I traced the actual state path for input `"*"` in mode `relative-ref`:
  `hier2`(140-142, default arm since first byte isn't `/`) → `path-nc-open`
  (169) → `path-nc-first`(170-175, default arm advances/continues) → EOF →
  `path-close-end`(166, shared terminal, part of the 159-166 block). So the
  code actually exercised is `path-nc-first` (168-175) plus the shared
  `path-close-end` node at 166 — **not** `path-scan`'s dispatch body
  (160-163), which is never reached for this input. The cited range
  (160-175) happens to include both the relevant `path-close-end` (166) and
  `path-nc-first` (168-175), so the citation is not wrong, but naming
  "path-scan" alongside "path-nc-first" as jointly responsible slightly
  overstates path-scan's role for this specific input.
- Measured, re-run:
  ```
  asterisk-form (relative-ref): mode=relative-ref input="*"
    scheme=<absent>  authority=<absent>  path="*"  query=<absent>  fragment=<absent>
  ```
  Identical to the original. **Status confirmed correct; two minor,
  non-substantive citation-precision notes above.**

## 5. Percent-decoding of the path for routing — status **present**: AGREE

- `src/uri/percent.sls:80-96` for `pct-decode` — confirmed exact:
  `(define (pct-decode bv)` opens at line 80, the function's closing parens
  are at line 96.
- `src/uri/normalize.sls:74-95` for `pct-normalize` — confirmed exact:
  `(define (pct-normalize bv)` opens at line 74, closes at line 95.
- The distinction drawn (full decode vs. unreserved-only decode) is
  accurate: `pct-decode` (percent.sls) decodes every valid `%XX`
  unconditionally; `pct-normalize` (normalize.sls:86-88) only emits the
  decoded octet `(if (unreserved-byte? v) (put-u8 out v) ...)`, else
  re-renders the triple uppercase. Matches the file exactly.
  **Citations and status confirmed correct.**

## 6. Dot-segment removal to prevent path traversal — status **present**: AGREE

- `src/uri/path.sls:121-163` for `remove-dot-segments` — the range covers
  `step` (121-139), `remove-dot-segments-trace` (141-153) and
  `remove-dot-segments` itself (155-163); the terminal function proper is
  actually 155-163, but citing the whole algorithm block it depends on is
  reasonable and not misleading.
- `src/uri/path.sls:100-102` for `drop-last-segment`'s no-op-on-empty
  behavior — confirmed exact: `(define (drop-last-segment out) (let ((k
  (last-slash out))) (if (fx<? k 0) empty-bv (bv-take out k))))` spans
  exactly 100-102, and does return `empty-bv` again when `out` is already
  empty (no `/` found ⇒ `k < 0`).
- `src/uri/percent.sls:76-79` for the single-pass "do not decode more than
  once" rule — confirmed exact (the comment block immediately above
  `pct-decode`'s loop).
- `src/uri/path.sls:8-14` for "opaque bytes"/"non-validating" — confirmed,
  matches the library-header comment verbatim.
- Measured (`uriparse-probe/probe2.sps`), re-run, **all 5 cases bit-for-bit
  identical** to the original, including the double-encoding-not-unwrapped
  case:
  ```
  plain traversal ".../etc/passwd" -> after remove-dot-segments="/etc/passwd"
  mixed traversal -> after remove-dot-segments="/etc/passwd"
  %2e%2e -> normalized="/a/../../etc/passwd" -> after remove-dot-segments="/etc/passwd"
  %252e%252e -> normalized (unchanged) -> after remove-dot-segments="/a/%252e%252e/etc/passwd"
  %2E%2E -> normalized="/a/../etc/passwd" -> after remove-dot-segments="/etc/passwd"
  ```
  **Citations and status confirmed correct.**

## 7. Query splitting / form-urlencoded decoding — status **missing**: AGREE, but **citation error**

- `rg -in "query-pair|form-urlencoded|split.*query" src/` — re-ran myself,
  **zero hits** (exit code 1). Confirms the claim.
- **Citation error**: the evidence cites
  `.plans/2026-09-18-chez-uri-project-brief.md:315-317` for the quoted text
  `"application/x-www-form-urlencoded query splitting ... chez-http-server
  will want it -- put it in a clearly separate module, or in the server,
  and do not let it into the URI grammar."` I read the file directly
  (`awk 'NR==282,NR==295'` and a full `nl -ba` pass over lines 270-325):
  **lines 315-317 are the WHATWG URL out-of-scope bullet**
  ("**WHATWG URL.** Different normative reference, different results on
  ordinary inputs, and mixing the two is the parser-differential security
  class..."), a *different* list item. The form-urlencoded bullet the item
  actually quotes is at **lines 319-322**:
  ```
  319: - **`application/x-www-form-urlencoded`** query splitting. RFC 3986's `query` is
  320:   opaque; `key=value&...` is an HTML convention. `chez-http-server` will want it
  321:   — put it in a clearly separate module, or in the server, and do not let it into
  322:   the URI grammar.
  ```
  The quoted prose is accurate and does appear in the file — only the line
  numbers are wrong (off by 4).
- Measured query-bytes claim, re-run: `"a=1&b=2&c"` for input
  `/x?a=1&b=2&c` — identical to the original.
  **Status and substance confirmed correct; the `:315-317` line citation is
  wrong and should read `:319-322`.**

## 8. Host grammar validation / Host header impact — status **missing**: AGREE

- `src/uri/vocabulary.sls:17-21,82-85` — confirmed exact both spans: line
  20 "userinfo/host/port and the host/charset errors are the core's,"; lines
  82-83 "userinfo/host/port -- which the forward-only machine cannot split
  cleanly -- are pure CORE functions over the `authority` bytevector, not
  scanner spans."
- `src/uri/grammar.sls:9-15,151-153` — confirmed exact both spans (library
  header SCOPE comment; and the `auth-open` block's leading comment
  "userinfo/host/port are the core's, split from this span's bytes").
- `src/uri/charset.sls:5-7` — confirmed exact: "PORT and every
  authority-interior charset (userinfo, host, reg-name, IP-literal) are
  M4's -- the authority is one opaque span until then (decision 0024 item
  2)."
- `src/uri/collect.sls:200-205` (`component-bytes`, no `authority` arm) and
  `:213-227` (`validate-result`, loops over `'(scheme path query
  fragment)` only) — both confirmed exact by direct read.
- `src/uri/normalize.sls:19-24,101-102` — confirmed exact: 19-24 is the
  "HOST case" bullet under "WHAT IT DOES NOT DO"; 101-102 is "authority
  case is left ALONE (host-case is M4/v0.2)."
- Measured (`uriparse-probe/probe3.sps`), re-run, **all 4 cases bit-for-bit
  identical**, including the security-relevant CR case:
  ```
  space in host -> ACCEPTED authority="exa mple.com"
  control char CR in host -> ACCEPTED authority="exa\rmple.com"
  malformed IPv6 host (no closing bracket) -> ACCEPTED authority="[::1"
  host with illegal byte and valid path/query/fragment -> ACCEPTED authority="ho<>st"
  ```
  **Citations and status confirmed correct — this is the report's strongest,
  most precisely cited item.**

## 9. Bytevector-in/out API and absent-vs-empty — status **present**: AGREE

- `src/uri/components.sls:45-51` for `check-field` — confirmed exact: the
  function spans exactly lines 45-51.
- `src/uri/components.sls:68,76-77` for `uri-component-absent?`/`empty?` —
  confirmed exact: line 68 is `uri-component-absent?`; lines 76-77 are
  `uri-component-empty?`.
- Measured, re-run:
  ```
  empty authority http:///p: authority=""  (present, empty)
  no authority http:/p: authority=<absent>
  ```
  Identical to the original. **Citations and status confirmed correct.**

## 10. Performance / allocation of `uri-parse` per request — status **partial**: AGREE, but **one factual error**

- Decision `0016-there-is-no-allocation-lane.md`: `:22` ("Not deferred —
  not wanted"), `:24-30` (pushes the property to byte-machine's retention
  lane), `:50-56` ("a number chosen to pass... indistinguishable from a
  noisy runner") — all three spans confirmed exact by direct read.
- `src/uri/collect.sls:134-135` (`make-eq-hashtable` × 2 inside
  `make-uri-collector`), `:173-182` (the collector's `feed!`/`finish!`
  dispatch), `:190-193` (`uri-parse`) — all confirmed exact.
- **Minor factual error**: the item states "a 66-byte origin-form target".
  I measured the actual `bench2.sps` target string
  (`"/api/v1/users/12345/orders?status=pending&sort=created_at&page=2"`)
  with both `wc -c` and Python `len()`: **it is 64 bytes, not 66.** This
  does not affect the timing/allocation numbers, which are about that
  string regardless of its mislabeled length.
- Measured, re-run **three separate times** for bench2.sps to check
  reproducibility:
  ```
  run 1: elapsed ms: 325  ns/parse: 1625.0  bytes/parse: 3766.7472
  run 2: elapsed ms: 318  ns/parse: 1590.0  bytes/parse: 3766.7472
  ```
  Byte counts are **bit-for-bit deterministic** across runs (as expected —
  allocation is not timing-noise-prone); nanosecond timings show ~2%
  run-to-run jitter, which is normal and does not undermine the
  conclusion. `bench3.sps` (construct-only): bytes/call **exactly**
  `2133.6568` on re-run (ns/call varied 875-900, i.e. the original's
  900.0 vs my 875.0, ~3% jitter — expected). `bench4.sps` (size-scaling):
  bytes/parse **exactly** `3362.0016` (short) and `5204.6576` (long) on
  re-run; ns/parse showed similar small jitter (1350-1420 short,
  2820-2890 long).
- I recomputed the "55-65% fixed overhead" claim: `2133.6568 /
  3766.7472 ≈ 56.6%`, which is within the claimed 55-65% band. Confirmed.
  **Status confirmed correct; the "66-byte" figure should read "64-byte."**

## 11. Relationship to chez-httparse's url sub-parser — status **present**: AGREE, but **one citation error, one minor imprecision**

- `chez-httparse/src/httparse/grammar.sls:727-728,756` for
  `on-url-data`/`on-url-complete`/`url-span` — confirmed exact: 727 is
  `on-url-data`, 728 is `on-url-complete`, 756 is
  `(make-span-declaration 'url-span 'on-url-data #f #f)`.
- `chez-httparse/src/httparse/grammar.sls:1053-1064` for the
  `make-field-branch-node 'url-which-entry ...` CONNECT-vs-normal branch —
  **minor imprecision**: the actual `make-field-branch-node` call spans
  lines **1063-1065** (I read `awk 'NR==1063,NR==1090'` directly); the
  cited range 1053-1064 covers the comment block above it plus the first
  two of the three lines of the call, but **cuts off line 1065**, which is
  where `'url-entry-connect 'url-entry-normal` — text the item explicitly
  quotes — actually appears. The quoted code is real and correctly
  transcribed; the line range just needs to extend one line further (to
  1065) to fully cover it.
- **Citation error**: `grammar.sls:1073-1076` is cited for the documented
  example `"OPTIONS a.com:443 HTTP/1.1" ... reads a.com as a schema, wants
  // after the colon, and errors`. I read the actual lines with
  `awk 'NR==1063,NR==1090'`:
  ```
  1073: ;; whole target is ONE `url-span`, which is what every `uri.md` fixture
  1074: ;; is written against; the url binary's five separate spans are the
  1075: ;; other configuration.
  1076: ;;
  1077: ;; WHAT THIS BUYS is the structural refusal the opaque loop could not
  1078: ;; make. `OPTIONS a.com:443 HTTP/1.1` reads `a.com` as a schema, wants
  1079: ;; `//` after the colon, and errors -- where a loop over the target
  1080: ;; characters read on to the end. That was the largest of the three
  ```
  **The OPTIONS example text is actually at lines 1077-1079, not
  1073-1076.** Lines 1073-1076 discuss a different point entirely (the
  spliced url-span being ONE span vs. the standalone parser's five
  separate spans). This is a genuine citation pointer error, four lines
  short of the real location — the claim itself (the worked example
  exists and says what's quoted) is true, just mis-cited.
- `docs/api.org` "~231-267" — read the file directly (`nl -ba`, lines
  220-270): the "* The url sub-parser" heading is at line 231, and the
  content described (five span callbacks, no percent-decoding, host
  carries userinfo+host+port undivided at line 254, re-entry on SP/CR/LF
  at 260-264, host-ending-at-`?` keeps the `?` at 266-267) all confirmed
  present and accurate through line ~268. The `~` (approximate) marker on
  this citation is honest and appropriate.
  **Status confirmed correct; the `1073-1076` citation is wrong (should be
  ~1077-1080), and the `1053-1064` citation should extend to 1065.**

## 12. IDNA and Unicode host handling — status **missing**: AGREE

- `.plans/2026-09-18-chez-uri-project-brief.md:318` — confirmed **exact**:
  line 318 reads verbatim "- **RFC 3987 IRIs**, IDNA, Punycode, Unicode
  mapping tables." under the "Out of scope, and say so in a decision
  record" heading (line 313). This is the most precisely cited single-line
  reference in the whole document. **Citation and status confirmed
  correct.**

## 13. IPv6 literal handling in authority — status **missing**: AGREE, minor citation imprecision

- `rg -in "ipv6|IP-literal" src/` — re-ran myself: exactly 3 hits, all in
  comments (`grammar.sls:81`, `charset.sls:6`, `vocabulary.sls:143`), none
  in executable code. Confirms the "absent from src/, only in comments"
  claim precisely (note: the item's own text cites `charset.sls:5-7` and
  `vocabulary.sls` generally for this, which I already verified above in
  item 8's citation block).
- `.plans/2026-09-18-chez-uri-project-brief.md:282-291` for the M4 host
  grammar scope and "150-250 nodes" estimate — **minor imprecision**: I
  read lines 282-295 directly; the M4 heading and scope text do start at
  line 282, but the specific "150–250 nodes plus the `ls32` tail" figure
  quoted in the item is actually at **line 293**, two lines past the cited
  range's end (291). Lines 282-291 do contain real, relevant M4-scope text
  (just not the exact quoted figure), so this is a softer error than items
  7 and 11's — an under-inclusive range rather than a wrong pointer.
- `.plans/2026-09-18-chez-uri-design.md` section 6, "~40-60 nodes" — I
  confirmed with `rg -n "40.?60|ls32|IPv6"` that line 339 does say
  "routing on `:` / `.` / `]` should come in near 40–60 nodes," and line
  334 says "And one to M4." No specific line number was cited by the item
  (it says "section 6" only), so there is nothing to refute here.
- Measured (`uriparse-probe/probe3.sps`), re-run: `"http://[::1/x"` ->
  `ACCEPTED authority="[::1"` — identical to the original (same run as
  item 8's probe3.sps).
  **Status confirmed correct; the project-brief line range should extend
  two lines further (to 293) to cover the quoted node-count figure.**

---

## Consolidated list of citation/factual errors found

| # | Item | Citation given | Problem | Correct location |
|---|------|---------------|---------|-------------------|
| 1 | Query splitting (item 7) | `.plans/2026-09-18-chez-uri-project-brief.md:315-317` | Points to the WHATWG URL bullet, not the quoted form-urlencoded bullet | `:319-322` |
| 2 | chez-httparse relationship (item 11) | `chez-httparse/src/httparse/grammar.sls:1073-1076` | Points to "ONE url-span vs five separate spans" text, not the quoted OPTIONS example | `~1077-1080` |
| 3 | IPv6 literal handling (item 13) | `.plans/2026-09-18-chez-uri-project-brief.md:282-291` | Range ends 2 lines short of the quoted "150-250 nodes" figure | extend to `:282-293` |
| 4 | Asterisk-form (item 4) | `src/uri/charset.sls:45` | The specific `(fx=? b 42)` byte-42 clause is on line 46, not 45 | `:44-46` (or `:46`) |
| 5 | chez-httparse relationship (item 11) | `chez-httparse/src/httparse/grammar.sls:1053-1064` | Quoted code (`'url-entry-connect 'url-entry-normal`) runs to line 1065, one line past the cited end | `:1054-1065` |
| 6 | Performance (item 10) | "a 66-byte origin-form target" | The actual bench2.sps target string is 64 bytes (verified with `wc -c` and Python `len()`) | 64 bytes |

None of these six issues change any status verdict (present/partial/missing)
or the practical consequence/workaround recommendation for their item — they
are citation-precision and one measurement-description defect, not
substantive errors. Every status label and every re-runnable empirical claim
in the 13-item gap analysis held up under adversarial re-verification.

## Reproduction commands (all run this session, cwd `/Users/yuzu/github/uriparse`)

```
chez --libdirs "src:vendor/byte-machine/src" --script /private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/uriparse-probe/probe.sps
chez --libdirs "src:vendor/byte-machine/src" --script /private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/uriparse-probe/probe2.sps
chez --libdirs "src:vendor/byte-machine/src" --script /private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/uriparse-probe/probe3.sps
chez --libdirs "src:vendor/byte-machine/src" --script /private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/uriparse-probe/bench2.sps   # re-run twice
chez --libdirs "src:vendor/byte-machine/src" --script /private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/uriparse-probe/bench3.sps
chez --libdirs "src:vendor/byte-machine/src" --script /private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/uriparse-probe/bench4.sps
printf '%s' '/api/v1/users/12345/orders?status=pending&sort=created_at&page=2' | wc -c   # -> 64
rg -in "query-pair|form-urlencoded|split.*query" src/     # -> no matches
rg -in "asterisk|OPTIONS|CONNECT|authority-form|origin-form|absolute-form" src/   # -> no matches
rg -in "ipv6|IP-literal" src/    # -> 3 hits, all comments (grammar.sls:81, charset.sls:6, vocabulary.sls:143)
```

Files read in full or by targeted range this session:
`src/uri/grammar.sls`, `src/uri/charset.sls`, `src/uri/percent.sls`,
`src/uri/collect.sls`, `src/uri/components.sls`, `src/uri/normalize.sls`,
`src/uri/path.sls`, `src/uri/vocabulary.sls` (targeted ranges),
`.plans/decisions/0016-there-is-no-allocation-lane.md`,
`.plans/decisions/0018-path-absolute-slash-is-recovered-by-an-event.md`,
`.plans/2026-09-18-chez-uri-project-brief.md`,
`.plans/2026-09-18-chez-uri-design.md` (targeted `rg`),
`/Users/yuzu/github/chez-httparse/src/httparse/grammar.sls` (targeted
ranges), `/Users/yuzu/github/chez-httparse/docs/api.org` (lines 220-270).
