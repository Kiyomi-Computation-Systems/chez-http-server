# 0021: the smuggling corpus is a hand-written fixed-vector lane, not a vendored generator or a probe reader

Date: 2026-10-04
Status: accepted (user decision, 2026-10-04, by form: "Static fixtures only", then "Per-case
verdict + gate")
Plan: [the milestone plan](../2026-09-20-chez-http-server-milestone-plan.md) §14's open list
(the last item)

## Context

Plan §14's open list carried "M8.3's smuggler corpus". Its M8.3 attempt was to vendor
`defparam/smuggler`'s and PortSwigger's Transfer-Encoding mutation generators and write a
reader that drives their probes at the server; that step was stopped by a safety classifier,
and the slice was dropped on a form ("Drop it from the slice"). The ledger kept the
measurement from that attempt: of 3,536 probes, all were refused but 6 gadgets that are no
Transfer-Encoding header at all. Guardian's 162 cases, already the robustness lane, cover the
same Transfer-Encoding classes.

Asked again, the owner chose not to re-open the vendored-generator path but to add a small,
hand-written, checked-in fixture set — "static fixtures only" — and, on a second form, to
record each case's verdict per case and gate it ("Per-case verdict + gate"), rather than
listing only refused cases.

Measured 2026-10-04 on Darwin arm64, Chez 10.4.1, feeding the canonical framing shapes
through the server's own parser to one fake connection:

| Family | Shape | Verdict |
|---|---|---|
| valid GET / valid chunked / `Content-Length: 0` | baselines | served (200) |
| CL.TE / TE.CL (both `Content-Length` and `Transfer-Encoding`, either order) | | refused 400 |
| duplicate `Content-Length` (equal or differing) | | refused 400 |
| malformed `Content-Length` (`+6`, `6a`, `6, 6`) | | refused 400 |
| space before the colon (`Transfer-Encoding : chunked`) | | refused 400 |
| duplicate `Transfer-Encoding` | | refused 400 |
| chunked not the final coding (`chunked, gzip`) | | refused 400 |
| an unimplemented coding before chunked (`gzip, chunked`) | | refused 501 |
| an unknown single coding (`cow`), `identity` | | refused 400 |
| a tab after the colon (`Transfer-Encoding:⇥chunked`) | | served — tab is OWS, chunked honoured |
| a look-alike name (`Transfer_Encoding`, `Transfer--Encoding`) | | served — an ordinary field, not a coding |

Every conflicting or obfuscated-coding gadget is already refused; the only served
obfuscations are the ones where framing stays unambiguous.

## Decision

1. **A standalone lane of hand-written fixed vectors.** `tests/smuggling-corpus.sls` holds
   nineteen request-framing vectors, authored here, one per canonical smuggling family. No
   code generates permutations and none drives a server: they are data and a byte assembler.
   Nothing is vendored, so there is no PROVENANCE gate (unlike guardian, decision 0007).
2. **Each case records its verdict and a category, gated two ways**
   (`tests/smuggling-lane.sls`, `tests/test-smuggling-lane.sps`):
   - THE VERDICT. Each case's measured verdict is the one recorded — `served`, or a refusal
     status — gated both ways, so serving a recorded refusal, refusing a recorded serve, or
     moving a refusal's status fails the lane until the corpus is updated under review.
   - THE SECURITY POLICY. Each case is a `safe` (served) or a `hazard` (refused), and the
     corpus's own category and recorded verdict must agree. A hazard can never be recorded
     as served, so a desync-enabling framing cannot be written into the corpus as acceptable.
3. **Chunk invariance is not re-gated here.** These vectors are refused (or served) at the
   head, before any body, and llhttp raises at the same byte however the bytes are split, so
   the outcome is invariant by construction. The property is gated across all 167 request
   fixtures by `(outcome-lane)` and guardian's 162 by `(robustness-lane)`, where bodies make
   the split matter. Re-asserting it here would add a check no mutant can redden.
4. **The vendored-generator and probe-reader path is deliberately not taken.** The item is
   settled by this lane, not deferred; a future session should not re-open the stopped step.

## Consequences

- Plan §14's open list is empty: every item is settled.
- No new dependency and no vendored file; the lane is test-only. No `CHANGELOG` entry —
  nothing a client or an embedder meets changes (as for the outcome and robustness lanes).
- The server's defence against request smuggling is now pinned twice: guardian's 162 cases
  (no Severe served) and these nineteen named framing vectors (no hazard served).
- Eight checks, each watched to fail; two reddened by code mutants of the status table in
  `(http-server decisions)` (an unimplemented coding's 501, and the parser-error 400). They
  are in `.superpowers/sdd/m8-mutations.md` ("After M8").
- Weighed and not taken: vendoring the generators and writing a probe reader (the dropped
  M8.3 path: a safety classifier stops writing it, and it duplicates guardian's classes);
  closing the item as already covered by guardian; and a refused-only fixture set, which
  cannot prove the served obfuscations are safe.
