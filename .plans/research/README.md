# Research behind the 2026-09-19 plan

Raw outputs of the planning research (LLM agents, 2026-09-19), kept as evidence. The curated documents are one level up.

- `spike/` — the live control-flow spike: scripts (`*.sps`), runner, raw outputs (`out/`; three runaway-loop logs replaced by head/tail excerpts), the report `spike-control-flow.md`, and the CSUG foreign-interface text it quotes. Run with the chez-libuv incantation in the report. E5d–E5f (added 2026-09-19, evening) reconcile E5c with chez-libuv's threading spike; they were written here directly, so the report's scratchpad paths apply only to E0–E6. `smoke-*.sps` (added 2026-09-19, night) are the upstream-landing checks the SDD ledger quotes verbatim: `smoke-upstream` (httparse decisions/methods, uriparse authority-form and host grammar), `smoke-writev` (chez-libuv `uv-write*!`), `smoke-finish` and `smoke-finish-42` (httparse `parser-finish!` for #33/#42), `smoke-v040` (#34 hand-off channels, #36 node-name split), `smoke-uriparse-v030` (uriparse `uri-collector-reset!` for #11, plus the one-shot fresh-vs-reuse measurement); run with the incantation the ledger gives beside each.
- `async-*.md` — six independent asynchrony-model proposals; `judge-*.md` — three judges' scorings.
- `corpus-*.md` — seven corpus finders by lens; `verify-*.md` — skeptic verdicts; `corpus-final.json` — the merged, verified catalogue; `corpus-tables.draft.md` — the rendered tables.
- `server-*.md` — reference-server deep reads (h11, hyper, Go, Node, h2o, nginx, warp, Scheme world).
- `gap-*.md` and `refute-gap-*.md` — dependency gap analyses and their citation refuters (the refuters corrected line numbers in three reports; substance held).
- `track2-final.json` — structured summary of the async, server and gap tracks.
- `stray-downloads/`, `*.java`, `*.tsv`, `*.txt` and the `fetched/`, `raw/`, `samples/`, `tarballs/`, `trees/` folders — material the finders fetched while verifying candidates; disposable.

Numbers quoted in the curated documents were taken from these reports on the day; a report's own commands and outputs are the source of truth for each.
