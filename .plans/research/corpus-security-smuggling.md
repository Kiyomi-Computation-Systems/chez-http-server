# Corpus research — lens: security / request smuggling

Author lens: SECURITY-SMUGGLING (one of seven corpus finders) for **chez-http-server**
(HTTP/1.1 server in R6RS Scheme for Chez 10.4.1, composed from chez-libuv / chez-httparse /
byte-machine / uriparse).

Date measured: **2026-09-19** on this machine (macOS arm64, Chez 10.4.1, `gh` 2.97.0).

## How to read the tiers and the (a)/(b)/(c) fit

The task defines three test surfaces our server exposes; every corpus below is tagged with which
it fits.

- **(a) in-process loopback TCP** — driven by chez-libuv's own client verbs (uv-tcp connect,
  uv-write!, on-data), single event loop, single thread.
- **(b) black-box against a listening port** — an external process (curl, a Python client, a
  DoS tool) hits a bound port.
- **(c) sans-I/O connection driver** — a pure function that takes a byte stream, splits it at
  every chunk boundary, and feeds `parser-feed!` the way chez-httparse already replays the 274
  llhttp fixtures at every chunk size. This is where the parser-differential value lives, and it
  is the surface that most needs a *static byte corpus with an expected verdict*.

Tiers: **1** = vendor now for the first milestones (copy bytes + a PROVENANCE file, exactly as
chez-httparse vendors llhttp); **2** = adapt later (needs extraction/transcoding work or a live
proxy); **3** = reference only (read it, mine ideas, do not vendor — usually GPL, or a live-only
framework with no static corpus).

### The vendoring template that already exists in this workspace

chez-httparse vendors the llhttp corpus as *verbatim upstream bytes* under
`test/vendor/llhttp/` with a `PROVENANCE` file and a registered CMake spec that (1) checksums
every listed file, (2) fails if a file on disk is unlisted, (3) fails if the declared count
disagrees. Header of that PROVENANCE:

```
# llhttp is MIT licensed (LICENSE beside this file, retained per 0007 item 7).
# This is test data; it is not part of the distributed library.
upstream-url: https://github.com/nodejs/llhttp
upstream-ref: v9.4.3-1-gee51043
upstream-commit: ee51043701d8b90ef647cf04790cbb1c55889825
retrieved: 2026-09-13
file-count: 24
sha256 628168...  LICENSE
sha256 2abc43...  request/content-length.md
...
```
(`/Users/yuzu/github/chez-httparse/test/vendor/llhttp/PROVENANCE`,
`/Users/yuzu/github/chez-httparse/test/support/cmake/CorpusProvenanceSpec.cmake:1`)

**Every Tier-1 recommendation below should be vendored the same way**: verbatim bytes, a
PROVENANCE with upstream commit + SHA-256s, LICENSE retained beside it, and a note that it is
test data not shipped in the library. The Apache-2.0 and MIT corpora permit this; the GPL ones
(http-garden, HTTPWookiee, haproxy) do **not** get vendored into a BSD-3 repo — they are read
for ideas and, where a specific short payload is a well-known published attack (a fact, not a
creative work), the *idea* is reimplemented in our own fixtures.

---

## Findings

### 1. aws/http-desync-guardian — YAML request-classification corpus  [TIER 1]

- URL: https://github.com/aws/http-desync-guardian
- License: **Apache-2.0** (confirmed: `gh api repos/aws/http-desync-guardian --jq .license.spdx_id` → `Apache-2.0`; `tests/README.md` badge; `LICENSE` is the Apache 2.0 text).
- Layer: **security** (also doubles as a spec checklist — the docs quote RFC 7230 §3.3.2 verbatim per case).
- Paths (all under `tests/`, fetched and counted with `rg -c '^\s*-\s*name:'`):
  - `tests/severe.yaml` — 70 cases (multiple/duplicate/bad Content-Length, multiple `Transfer-Encoding: chunked`, bad TE values, bad method/URI/version, NUL/CR in header)
  - `tests/ambiguous.yaml` — 90 cases (`Transfer-Encoding ` trailing-space name, `\x01Transfer-Encoding`, both-TE-CL, empty header, obs-fold)
  - `tests/bad-header-characters.yaml` — 38
  - `tests/real-life-test-cases.yaml` — 240 (browser-realistic requests with one poisoned framing header)
  - `tests/more-compliant-tests.yaml` — 117, `tests/rfc-compliant.yaml` — 34, `tests/acceptable.yaml` — 22, `tests/edge-cases.yaml` — 26, `tests/uri-specific-test-cases.yaml` — 28, `tests/single-case.yaml` — 3
  - **Total: 668 named cases** (`cat tests/*.yaml | rg -c '^\s*-\s*name:'` → 668).
- Format: structured YAML — each case is `{name, uri, method, version, headers:[{name,value,tier}], expected:{tier, reason, required_message_items}}`. `tier` ∈ Compliant/Acceptable/Ambiguous/Severe; `reason` ∈ a fixed enum (MultipleContentLength, BadContentLength, BothTeClPresent, MultipleTransferEncodingChunked, SuspiciousHeader, BadHeader, …). Header names/values carry `\xNN` escapes and leading spaces. Schema is documented in `tests/README.md` (fetched to `files/desync-guardian/tests-README.md`); the verdict taxonomy is in `docs/README.md` (fetched to `files/desync-guardian/docs-README.md`).
- Covers: the entire CL/TE ambiguity surface our RFC-9112-§6.3 framing logic must get right, each case tagged with the *correct* server verdict and the RFC clause behind it. This is the single best-labelled corpus for us because it is I/O-free by construction ("The test suite must require no knowledge about the library/programming languages but only about HTTP protocol") — the authors explicitly built it for reviewability and re-use.
- Adapt: fits **(c)** perfectly. Write a small Scheme reader that turns each YAML case into request bytes (join headers with CRLF, apply `\xNN`), feed our connection driver at several chunk sizes, and assert our framing decision maps to the case's `tier`/`reason`. Note the guardian classifies *headers already parsed*, so a handful of cases assume a permissive parser; where our parser rejects earlier (chez-httparse), map "we 400 before classifying" onto Severe/Ambiguous as an accept. Two caveats found in the data: (i) values often carry a deliberate leading space (`value: " 22"`) that is part of the test; (ii) one real-life case references "1614 bytes" of body but the bytes are described, not embedded — that one is not directly replayable.
- Effort: low. ~1 day for the YAML→bytes reader; the mapping table from our error codes to their `reason` enum is the real work.

### 2. h2o/h2o `fuzz/http1-corpus` — real fuzzer seed corpus  [TIER 1]

- URL: https://github.com/h2o/h2o, directory `fuzz/http1-corpus/`
- License: **MIT** (`gh api repos/h2o/h2o --jq .license.spdx_id` → MIT; `LICENSE` = "Copyright (c) 2014 DeNA Co., Ltd.").
- Layer: **parser** (raw byte seeds), some multi-request.
- Paths / size: `fuzz/http1-corpus/` — **1972 files, 2,525,951 bytes total** (measured by resolving the directory tree SHA and counting: `gh api repos/h2o/h2o/git/trees/999b06ba9333e242d154acaee890e5fa7817b784 --jq '.tree|length'` → 1972, `truncated:false`; note the Contents API pages at 1000, which is why a naive `contents` call under-reports). Also `fuzz/url-corpus/` (90 files) for uriparse. `fuzz/README.md` and `fuzz/driver.cc` fetched to `files/h2o/`.
- Format: raw request bytes. **Critical detail**: the driver splits each seed on the literal marker `\n--MARK--\n` and writes each segment as a separate TCP packet (`fuzz/driver.cc:153` `#define MARKER "\n--MARK--\n"`, then `memmem`/`write` loop at :156-161). So a seed already *encodes its own packetization*, which is exactly the chunk-boundary information our sans-I/O driver wants. Sample seeds contain smuggling-shaped payloads: file `008dd45d...` has `Transfer-Encoding: chunked` fragments + chunk body + trailing NULs; `006501e9...` is a keep-alive pipeline of malformed request-lines.
- Covers: broad, coverage-minimized malformed-request space including chunked framing, header junk, embedded NULs, pipelines — the "did the fuzzer already find this shape" set. Complements the *labelled* guardian corpus with a large *unlabelled* differential set.
- Adapt: fits **(c)** and **(a)**. For (c): strip/interpret `--MARK--` into a chunk-split list, feed each seed, assert the parser never crashes and either finishes cleanly or returns `'error` with a byte offset — this is a robustness/oracle corpus, not an expected-verdict corpus. For a true differential you would run llhttp over the same bytes (chez-httparse already has a live llhttp differential harness we can point at these). No expected outputs ship, so its value is crash-freedom + parser-vs-llhttp agreement.
- Effort: low to vendor (copy bytes + PROVENANCE), medium to get differential value (reuse chez-httparse's llhttp oracle). 2.5 MB is well under any size concern.

### 3. nodejs/node HTTP smuggling regression tests — concrete labelled payloads  [TIER 1]

- URL: https://github.com/nodejs/node, files under `test/parallel/`
- License: **MIT** (repo license field is NOASSERTION because the tree bundles many licenses, but `LICENSE` core grant is the MIT text "Copyright Node.js contributors"; these test files are original Node work under that MIT grant).
- Layer: **security / server** (each test is server-behaviour: send bytes, assert the server answers `400`/closes and never invokes the handler).
- Paths + what each asserts (all fetched to `files/node/`):
  - `test/parallel/test-http-chunked-smuggling.js` — invalid chunk extension (`2;\nxx`) used to smuggle `GET /admin`; asserts `/admin` never reached. First commit 2978b5a4a3 (2021-08-25).
  - `test/parallel/test-http-transfer-encoding-smuggling.js` — `Transfer-Encoding: chunked` + `Transfer-Encoding: chunked-false`, and a folded `, chunked-false` continuation; asserts `400`. Commit history maps it to **CVE-2020-8287, CVE-2022-32212/13/14/15, CVE-2022-35256, CVE-2024-27982**.
  - `test/parallel/test-http-transfer-encoding-repeated-chunked.js` — `Transfer-Encoding: chunkedchunked`; asserts `400`. Ties to **CVE-2022-32212/14/15** (commit d9b71f4c24 "stricter Transfer-Encoding and header separator parsing").
  - `test/parallel/test-http-dummy-characters-smuggling.js` — bytes after a bare `\r` (`Host: a\r\nZ`) and a bad chunk terminator (`5\r\r;ABCD`); asserts `400`. Added with the llhttp 9.1.2 bump (e9ff81016d).
  - `test/parallel/test-http-request-smuggling-content-length.js` — space before colon (`Content-Length : 5`); asserts `400`.
  - `test/parallel/test-http-server-reject-chunked-with-content-length.js` — CL + TE together; asserts parser error `HPE_INVALID_TRANSFER_ENCODING`.
  - `test/parallel/test-http-double-content-length.js` — two Content-Length values; asserts `HPE_UNEXPECTED_CONTENT_LENGTH`.
  - Also present: `test-http-content-length-mismatch.js`, `test-http-response-multi-content-length.js`, `test-http-allow-content-length-304.js`, `test-http-no-content-length.js`, `test-http-client-reject-chunked-with-content-length.js`. **~14 files.**
- Covers: the canonical smuggling regressions of the most-attacked JS runtime, each with an explicit expected outcome (400 / specific parser error code) and, via git blame, a **CVE mapping** we can cite in our own ratchet. Because chez-httparse targets llhttp behavioural compatibility, and Node *is* the reference llhttp consumer, these are near-oracle for us.
- Adapt: fits **(a)** and **(c)**. The byte payloads lift straight out of the `client.write('...')` string literals into Scheme bytevector fixtures; the assertions ("400 Bad Request, Connection: close" / handler-never-called) become our connection-layer assertions. Reimplement as our own fixtures citing the Node file + CVE (do not copy the JS harness). ~15-30 payloads.
- Effort: low. Manual lift of ~15 payloads + expected verdicts.

### 4. defparam/smuggler — Transfer-Encoding mutation generators  [TIER 1 (as a generator to port), TIER 2 (as-is)]

- URL: https://github.com/defparam/smuggler
- License: **MIT** (`LICENSE` "Copyright (c) 2020 Evan Custodio"; `lib/Payload.py` carries the MIT header inline).
- Layer: **security** (TE/CL obfuscation catalogue).
- Paths: `configs/default.py`, `configs/doubles.py`, `configs/exhaustive.py`, `lib/Payload.py`. Each config builds a `mutations` dict of Transfer-Encoding obfuscations against a fixed request template. **Exact counts, measured by executing each config with a stub `Payload` (see `files/smuggler/` and the inline python I ran): default = 134, doubles = 966, exhaustive = 668 mutations.**
- Covers: the definitive named catalogue of TE-header obfuscations — `nameprefix1` (` Transfer-Encoding: chunked`), `tabprefix1/2` (`\t`), `spacejoin1`/`underjoin1`/`smashed`, `space1` (`Transfer-Encoding : chunked`), `vertprefix1` (`\x0B`), `commaCow`/`cowComma` (`chunked, cow`), `contentEnc`, `linewrapped1` (obs-fold), `quoted`/`aposed`, `lazygrep` (`chunk`), `sarcasm`/`yelling` (case), `0dsuffix`/`tabsuffix`, `revdualchunk`, `0dspam` (`Transfer\r-Encoding`), `nested`, `spaceFF`/`accentCH`/`accentTE` (high bytes 0x82/0x96/0xFF), plus a systematic sweep inserting bytes 0x01–0xFF at the mid/post/pre/end positions of the header (`midspace-XX`, `postspace-XX`, `prespace-XX`, `endspace-XX`, `xprespace`, `endspacex`, `rxprespace`, `xnprespace`). These are the exact byte positions our chunked/TE detector must classify.
- Adapt: fits **(c)**. Do **not** vendor the Python; instead port the *mutation table* (the finite set of gadget strings) into a Scheme data file and generate the request bytes ourselves — the value is the enumerated positions/bytes, which are facts about HTTP parsers, not a creative work. Each mutation → one request; expected verdict for our strict parser is "reject or treat-as-non-chunked, never smuggle". Cross-check against finding #1's SuspiciousHeader cases (large overlap of names — nameprefix1/tabprefix1/space1/etc. appear in both, which is corroboration).
- Effort: medium (port the generator, decide expected verdicts per mutation — the guardian corpus supplies many of those verdicts already).

### 5. PortSwigger/http-request-smuggler — DesyncBox permutation catalogue + probe payloads  [TIER 2]

- URL: https://github.com/PortSwigger/http-request-smuggler
- License: **Apache-2.0** (`LICENSE` = "Copyright 2022 PortSwigger Web Security / James Kettle", Apache 2.0 text; repo license field NOASSERTION because the tree bundles `turbo-intruder.jar`).
- Layer: **security** (this is a Burp extension — a live attack tool, not a static corpus, hence Tier 2).
- Paths worth extracting:
  - `src/burp/DesyncBox.java` — `register(...)` calls enumerate the full permutation set (~90 names): shared (`vanilla, underjoin1, spacejoin1, space1, nameprefix1/2, valueprefix1, vertwrap, connection, spjunk, backslash, spaceFF, unispace, commaCow, cowComma, contentEnc, quoted, aposed, dualchunk, lazygrep, 0dsuffix, tabsuffix, revdualchunk, nested, encode, accentTE, accentCH, removed, get/options/head, range, qencode, qencodeutf, nel, nbsp, shy, shy2`, plus `spacefix1:/prefix1:/suffix1:/namesuffix1:` × specialchars {0,9,11,12,13,127}), H1-only (`nospace1, linewrapped1, doublewrapped, gareth1, badsetupCR, badsetupLF, multiCase, tabwrap, UPPERCASE, 0dwrap, 0dspam, badwrap, bodysplit, h1case, http1.0`), and CL-mutations (`CL-plus, CL-minus, CL-pad, CL-bigpad, CL-e, CL-dec, CL-commaprefix, CL-commasuffix, CL-expect, CL-expect-obfs, CL-error, CL-spacepad, CL-byteranges, CL-multiform, CL-deleteMaxforward, CL-gzip10, CL-dualCL`). The `applyDesync` method (lines 140-330, fetched) gives the exact byte transform for each name — e.g. `gareth1` = `header.replace(":", "\n :")`, `spjunk` (Amit Klein) = `replace(":", " x:")`, `backslash` = `replace("-", "\\")`, `nel/nbsp/shy` insert U+0085/U+00A0/U+00AD.
  - `src/burp/ProbePayloads.java` — 13 smuggled-prefix payloads used as CL.0 attack bodies (`TRACE /asdf HTTP/1.1\r\nA: B`, `GET /0-9 HTTP/0.9`, `GET /invalid HTTP/1.2`, `GET /%2f HTTP/1.1`, a pipelined `GET / … GET / …`, a `CONNECT …psres.net:443`).
  - `resources/CL-TE.py`, `resources/TE-CL.py`, `resources/H2-TE.py`, `resources/H2-TUNNEL.py` — Turbo-Intruder attack scripts (live-attack, not corpus).
- Covers: the current-state-of-the-art permutation names and their byte transforms, including the CL-side mutations that finding #4 lacks (CL padding, byteranges, expect-obfuscation). This is the superset our defensive test matrix should aim to reject.
- Adapt: fits **(c)** as a *permutation catalogue* (port the `applyDesync` transform table into Scheme, apply to a base request, assert rejection). The `.py` resources and the jar are live-attack machinery, not for us. Because it is Apache-2.0 we *may* vendor the extracted transform table with attribution, but porting is cleaner than vendoring Java.
- Effort: medium-high (transcribe ~90 transforms; overlaps finding #4, so do #4 first and add only the CL-side and Klein/Kettle-named extras).

### 6. RFC 9112 §11 + §6.3 — the framing checklist the corpora instantiate  [TIER 1 as a checklist]

- URL: https://www.rfc-editor.org/rfc/rfc9112.html (§6.3 message body length, §11 security considerations).
- License: IETF Trust / RFC — quotable as a normative reference, not vendored as data.
- Layer: **spec**.
- Content we rely on (fetched and summarised):
  - §6.3 body-length rules 1-8: HEAD/1xx/204/304 → no body; 2xx CONNECT → tunnel; **TE present → TE wins, intermediary MUST strip CL**; chunked-as-final determines length; **invalid Content-Length with no TE is unrecoverable → 400/close**; valid CL defines length; neither present → 0-length request body.
  - §11.1 response splitting (filter CRLF out of emitted headers), §11.2 request smuggling (tighten framing per §6.3), §11.3 message integrity / truncation, §11.4 confidentiality.
- Covers: the authoritative list of MUSTs that findings #1-#5 supply concrete bytes for. Use it as the spine of `.plans/decisions/` for the connection layer's framing rules, and to justify each expected verdict.
- Adapt: fits all three surfaces as an assertion source. No extraction; it is the rubric.
- Effort: none (reference).

### 7. bahruzjabiyev/T-Reqs — grammar-based differential fuzzer (CCS 2021)  [TIER 2]

- URL: https://github.com/bahruzjabiyev/T-Reqs
- License: **MIT** (`LICENSE` "Copyright (c) NEU SecLab").
- Layer: **security / load** (a fuzzer, not a static corpus).
- Paths: `config`, `misc/example-request-line-grammar`, `misc/example-request-headers-grammar` (330 lines — a full header CFG with a `<entity-size-header>` production that emits CL, TE, CL+TE, and TE+CL orderings), `misc/example-request-body-grammar` (chunked-body grammar with trailer productions), `code/*.py` (tree/string mutator, feedback server). Paper: "T-Reqs: HTTP Request Smuggling with Differential Fuzzing", ACM CCS 2021 (http://seclab.nu/static/publications/ccs2021treqs.pdf).
- Covers: a *generator* of well-formed-but-adversarial requests, especially the CL/TE header-ordering matrix and chunked-body/trailer permutations. The grammars are the reusable asset (the mutator needs a reverse-proxy feedback server we will not stand up early).
- Adapt: fits **(c)** eventually — port the request-line/header/body CFGs into a small Scheme generator to produce seeds for the sans-I/O driver, then differential against llhttp. The Python runtime and the coverage-feedback loop are out of scope for the first milestones.
- Effort: high (port grammars + a generator; deferred until we have the differential harness running).

### 8. shekyan/slowhttptest — slow-client / DoS timeout tester  [TIER 2]

- URL: https://github.com/shekyan/slowhttptest
- License: **Apache-2.0** (`LICENSE`/`COPYING` = Apache 2.0).
- Layer: **load** (defensive availability testing only — the README is explicit it is for systems you own).
- Paths: C++ classic tool in `src/`; a modern C++ rewrite `slowhttptest-ng` under `ng/` adds chunked-body hold, Expect/100-continue hold, slow TLS. Attack modes: slow headers (`-H`), slow body (`-B`), range (`-R`), slow read (`-X`); ng adds `--chunked`, `--expect-continue`. Installable on macOS via Homebrew (`brew info slowhttptest` → stable 1.10.0) or Docker (`shekyan/slowhttptest:latest`).
- Covers: exactly the header-timeout / body-timeout / idle-timeout / slow-read backpressure policy the architecture doc §11 calls for (`limits.sls`). It validates that our timers (chez-libuv `make-uv-timer`) and `uv-read-stop!` backpressure actually shed slow clients.
- Adapt: fits **(b) only** — it is an external binary against a bound port. Not a static corpus; it belongs in a `make test-slow` / CI availability check, not the sans-I/O suite. Runs on this Mac today.
- Effort: low to wire into a black-box test target once the server binds a port; no vendoring (it is a tool, invoked, not copied).

### 9. haproxy VTC reg-tests (http-messaging) — framing/desync conformance scripts  [TIER 3 (GPL) → reimplement]

- URL: https://github.com/haproxy/haproxy, `reg-tests/http-messaging/`
- License: **GPL-2.0** (with LGPL headers + OpenSSL exception; `LICENSE`). **Do not vendor into a BSD-3 repo.**
- Layer: **reference-impl / server**.
- Paths (fetched to `files/haproxy/`): `http_transfer_encoding.vtc` (19 client blocks, 22 status expectations — TE-chunked framing, `Transfer-Encoding: chunked, chunked` → 400, `gzip, chunked` → 422, trailer validation, a `Content-Length: 31` + chunked "GET /smuggled" desync attempt → connection close), `h2_desync_attacks.vtc` (H2→H1 pseudo-header/authority-vs-host desync), `h1_request_target_validation.vtc` (13 cases: `OPTIONS *`, absolute-form, CONNECT authority-form, reject `GET *`, reject bare `admin`), `truncated.vtc`, `h1_to_h1.vtc`. Format is Varnish VTC (`client { txreq … } expect resp.status == 400`), run by VTest2 (https://github.com/vtest/VTest2).
- Covers: a mature, adversarial expected-verdict set for TE lists, trailers, and request-target forms — a superb *design reference* for what verdict a hardened server gives.
- Adapt: fits **(a)/(b)** in spirit but the VTC harness is heavyweight and GPL. **Reimplement the cases** as our own Scheme fixtures citing the .vtc file (the request bytes + expected status are facts; the VTC script is the GPL creative work we do not copy). High value as a checklist, low as a droppable asset.
- Effort: medium (transcribe the interesting cases by hand).

### 10. narfindustries/http-garden — differential framework + TROPHIES payloads  [TIER 3 (GPL) → mine ideas]

- URL: https://github.com/narfindustries/http-garden
- License: **GPL-3.0** (`LICENSE`; README funded by DARPA HR0011-19-C-0076). **Do not vendor.**
- Layer: **security / reference-impl**.
- Paths: no static corpus directory — payloads are generated live in a Docker-based REPL against 41 servers / 15 transducers (`tools/repl.py`, `tools/mutations.py`, `tools/http1.py`). BUT: `TROPHIES.md` (57 KB, ~85 entries containing literal `\r\n` payloads) documents each found bug with a concrete "Payload:" line, e.g. chunk-size `0_2e` (Python int parsing), NUL/CR in header values, whitespace-stripped header names (`Content-Length : 34`) — and maps each to CVEs (CVE-2023-47627 etc.). `quirks.yml` records per-server parsing quirks (duplicate-header joiners, method blacklists, HTTP/0.9 acceptance). Runs on Linux x86_64/AArch64 only (Docker), not this Mac directly.
- Covers: the richest catalogue of *real* parser discrepancies with server attribution and CVEs — the best source for "what discrepancy should our differential harness look for". `mutations.py`'s `_SEED_HEADERS` and meaningful-byte set (`\r\n`, `\r`, `\n`, `\x00`, `:`, `\t`, ` `) is a good guide for our own fuzz alphabet.
- Adapt: fits **(c)** as an idea source and, later, **(b)** if we add our server to the Garden's Docker matrix (best long-term differential validation, but GPL framework + Linux + Docker → not milestone-1). Mine `TROPHIES.md` payloads into our own fixtures (payload bytes are published attack facts) with attribution to the trophy + CVE; do not copy the framework.
- Effort: low to mine payloads; high to integrate as a live target.

### 11. regilero/HTTPWookiee — RFC-7230 smuggling stress tests  [TIER 3 (GPL, stale)]

- URL: https://github.com/regilero/HTTPWookiee
- License: **GPL-3.0** (`LICENSE`). Last pushed **2017-12-02** (stale). **Do not vendor.**
- Layer: **security**.
- Paths: `httpwookiee/client/tests_chunks.py` (15 test methods — chunk+CL mixing, chunk header hidden by NUL / bad EOL, chunk-size truncation/overflow with trailers), `tests_first_line.py` (21 — request-line separators, CR/LF/CRLF line prefixes, bogus versions HTTP/0.8, HTTP/-1.0, HTTP/65536.9), `tests_host.py`, `tests_regular.py`. Tests build requests programmatically (`req.add_chunk(...)`, `req.add_header(...)`), so there is no flat corpus to lift — the payloads are constructed in code.
- Covers: chunk-size overflow/truncation and request-line edge cases that overlap but extend llhttp's fixtures; good idea source for chunk-parser hardening.
- Adapt: fits **(c)** only via manual transcription of the constructed payloads. GPL + stale + code-not-data → **reference only**. Read `tests_chunks.py` for the chunk-overflow ideas, reimplement the few we want.
- Effort: medium (read Python, transcribe by hand); low priority.

### 12. nginx-tests — Perl framing/header tests  [TIER 3 → mine ideas]

- URL: https://github.com/nginx/nginx-tests
- License: **BSD-2-Clause** (`LICENSE` = "Copyright (C) 2008-2011 Maxim Dounin", 2-clause BSD) — *vendorable* in principle, but the payloads are embedded in Perl harness code, not a flat corpus.
- Layer: **reference-impl / server**.
- Paths (fetched to `files/nginx-tests/`): `body_chunked.t` (chunked body, pipelined chunked, runaway chunk → 400, `Transfer-Encoding: identity` → 501, `chunked\nTransfer-Encoding: chunked` repeat → 400, `chunked\nContent-Length: 5` → 400, chunked in HTTP/1.0 → 400), `http_headers_multi.t` (47 assertions on duplicate-header handling), `ignore_invalid_headers.t`, `proxy_chunked*.t`, `proxy_duplicate_headers.t`. Format: Perl `Test::Nginx`, requests built with `CRLF` concatenation.
- Covers: nginx's expected verdicts on the same TE/CL/duplicate-header surface — a second reference implementation to cross-check against Node (finding #3) and HAProxy (finding #9). Where Node/llhttp and nginx *disagree*, that is a discrepancy our design must consciously choose.
- Adapt: fits **(a)/(c)** via transcription of the `http_transfer_encoding(...)` request builders and their expected statuses. BSD-2 means we *could* vendor the .t files with attribution, but they need Perl+nginx to run, so treat as reference and reimplement the ~8 framing assertions.
- Effort: low-medium (transcribe ~8-10 framing cases).

### 13. Also-confirmed / lower-value (not separate findings)

- **anshumanpattnaik/http-request-smuggling** — MIT (`LICENSE` "Copyright (c) 2020 Anshuman Pattnaik"). `payloads.json` has **38** `permute` entries + **2** `detection` payloads (CL.TE `\r\n1\r\nZ\r\nQ\r\n\r\n` CL=5; TE.CL `\r\n0\r\n\r\n\r\nG` CL=6). It is a strict subset of defparam/smuggler's names (spacejoin, underjoin, tabprefix, gareth1, badsetupCR/LF, dualchunk, …), so **finding #4 supersedes it**; skip unless you want the two ready-made detection bodies. Fits (c). Tier 2/skip.
- **swisskyrepo/PayloadsAllTheThings** — MIT, `Request Smuggling/README.md` (181 lines) lists the Kettle TE-variant block (`Transfer-Encoding: xchunked`, `Transfer-Encoding : chunked`, tab-prefixed, `X: X[\n]Transfer-Encoding: chunked`, split-line `Transfer-Encoding\n: chunked`) and CL.0/CSD examples. Pure documentation, no expected verdicts; **reference only** to sanity-check our variant list is complete. Tier 3.
- **PortSwigger research writeups** (facts, cited for design rationale, no corpus to vendor): *HTTP Desync Attacks* (Kettle, 2019-08-07) — CL.TE/TE.CL/TE.TE taxonomy + the 7 TE obfuscation lines; *Browser-Powered Desync* (2022-08-10) — client-side desync, **pause-based desync** (Apache/Varnish hold partial requests ~15s without closing → our header/body timeout MUST close, not just idle), H2.0 downgrade; *HTTP/1.1 Must Die* (2025-08-06) — **0.CL** and **Expect-based** desync, V-H/H-V parser-discrepancy framing, and the implementer advice we should adopt: reject bodies on GET/HEAD/OPTIONS, enable all normalization, treat any CL/TE ambiguity as fatal. These justify specific expected verdicts in findings #1/#3/#5.
- **aws http-desync-guardian** also serves as a *reference implementation* (Rust `src/request_analyzer.rs`) of the classification we can consult, beyond its YAML corpus.
- **Varnish note**: `varnishcache/varnish-cache` was **archived 2026-02-16** and the project moved to a self-hosted Forgejo (code.vinyl-cache.org) as "Vinyl Cache". Its VTC tests are reachable through HAProxy's reg-tests (finding #9) instead; do not rely on the archived GitHub repo as a live source. (`gh api repos/varnishcache/varnish-cache --jq .archived` → true; WebSearch confirmation.)

---

## Recommended milestone-1 vendoring set (the "vendor now" shortlist)

1. **aws/http-desync-guardian `tests/*.yaml`** (Apache-2.0, 668 labelled cases) — vendor verbatim under `test/vendor/http-desync-guardian/` with PROVENANCE; build a YAML→bytes→verdict reader. *The keystone corpus.*
2. **h2o `fuzz/http1-corpus/`** (MIT, 1972 seeds, 2.5 MB) — vendor verbatim under `test/vendor/h2o-http1-corpus/` with PROVENANCE; robustness + llhttp-differential replay via the `--MARK--` split.
3. **nodejs/node smuggling tests** (MIT) — reimplement ~15 payloads as native fixtures citing file + CVE.
4. **defparam/smuggler mutation table** (MIT) — port the finite TE-mutation catalogue (134/966/668) into a Scheme generator; expected verdicts cross-referenced to #1.
5. Keep **RFC 9112 §6.3/§11** as the checklist spine in `.plans/decisions/`.

GPL corpora (http-garden, HTTPWookiee, haproxy) and doc-only sources (PayloadsAllTheThings, Kettle writeups) are **read for ideas / reimplemented**, never copied into this BSD-3 repo.

## Provenance of this report's claims

Every license was confirmed by fetching the repo's `LICENSE` (or `gh api repos/<r> --jq .license.spdx_id`), not from memory. Every file path + count was confirmed by fetching the repo tree (`gh api .../git/trees/HEAD?recursive=1`) and, for the corpora we counted, by downloading the files into `/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/research/files/` and running `rg -c` / executing the config scripts. The h2o corpus count (1972, not the Contents-API's 1000-page cap) was verified by resolving the directory tree SHA. Node CVE mappings came from `gh api repos/nodejs/node/commits?path=...` blame. Downloaded artifacts and trees are under `scratchpad/research/files/` and `scratchpad/research/trees/` for the synthesis agent.
