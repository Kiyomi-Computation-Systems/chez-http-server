# Gap analysis: uriparse v0.1.0 for chez-http-server's request-target

Library under test: `uriparse` at `/Users/yuzu/github/uriparse`, commit surface as of
2026-09-19 (README.org says "Status: v0.1.0 — released 2026-09-19"; `CHANGELOG.md`
`[Unreleased]` section is empty, so HEAD is the v0.1.0 release plus no landed
changes). Read: `README.org`, `.plans/2026-09-18-chez-uri-design.md`,
`.plans/2026-09-18-chez-uri-project-brief.md`, `.plans/decisions/000{1,4,8,9,10,
11,16,18,19,20,21,22,24}-*.md`, and every file under `src/uri/` and
`src/generated/`. Cross-checked against `chez-httparse` at
`/Users/yuzu/github/chez-httparse` (`docs/api.org`, `src/httparse/url-grammar.sls`,
`src/httparse/grammar.sls`) for item 7.

All file:line citations below were read directly from source with `Read`/`rg`/`sed`
in this session, not taken from README prose alone. Where I could settle a
question empirically I wrote and ran a Chez program under this task's scratchpad
(`/private/tmp/claude-501/.../scratchpad/uriparse-probe/*.sps`) with:

```
chez --libdirs "src:vendor/byte-machine/src" --script <file>.sps
```
run with cwd `/Users/yuzu/github/uriparse`. Full commands and verbatim output are
inlined per item below.

---

## 1. The four RFC 9112 §3.2 request-target forms

uriparse has **no concept of request-target forms** — it is a generic RFC 3986
`URI` / `relative-ref` / `URI-reference` splitter (three `mode` values,
`src/uri/vocabulary.sls:56-60`), not an HTTP request-line parser. None of
"origin-form", "absolute-form", "authority-form", "asterisk-form", "CONNECT" or
"OPTIONS" appears anywhere under `src/` (`rg -in "asterisk|OPTIONS|CONNECT|
authority-form|origin-form|absolute-form"` inside `uriparse/` returns zero hits
outside `.plans/`; command run this session, zero matches). The server must pick
the mode and, for two of the four forms, must special-case the input before
handing it to uriparse. Empirically verified in
`scratchpad/uriparse-probe/probe.sps`, run with the command above; full output
captured below per form.

### origin-form (`/path?query`)
**Present**, via `mode = 'relative-ref` (grammar `hier2`/`hier-slash1`/`path-open`,
`src/uri/grammar.sls:140-149,159-166`).
```
origin-form (relative-ref): mode=relative-ref input="/path/to/thing?q=1&a=2"
  scheme=<absent>
  authority=<absent>
  path="/path/to/thing"
  query="q=1&a=2"
  fragment=<absent>
```
**Caveat, measured, not documented anywhere in uriparse**: `relative-ref` mode
also accepts a leading `//`, which RFC 9112's `absolute-path` production for
origin-form must not (that shape is authority syntax). Grammar evidence:
`hier2` (`src/uri/grammar.sls:140-142`) dispatches a `SLASH` to `hier-slash1`
(`:145-149`), which on a *second* `SLASH` opens the `authority` span
(`adv 'auth-open`) exactly as mode `uri` does after a scheme. Measured:
```
origin-form starting //  (ambiguity check): mode=relative-ref input="//evil.com/path"
  scheme=<absent>
  authority="evil.com"
  path="/path"
  query=<absent>
  fragment=<absent>
```
**The server must reject (or otherwise special-case) a request-target that
begins with `//` before calling uriparse in `relative-ref` mode**, or it will
silently split an origin-form target into an "authority" the client only
intended as two empty path segments — a classic origin-form/absolute-form
confusion vector. uriparse gives no help here; this is a request-target-level
check the server has to write itself.

### absolute-form (`http://host/path`, required for proxies, and origin
servers must accept it per RFC 9112 §3.2.2)
**Present**, via `mode = 'uri` (`src/uri/grammar.sls:125-131` scheme scan,
then the `hier`/`hier-slash1`/`auth-open` chain, `:137,145-156`).
```
absolute-form (uri): mode=uri input="http://example.com:8080/path?q=1"
  scheme="http"
  authority="example.com:8080"
  path="/path"
  query="q=1"
  fragment=<absent>
```
No special-casing needed beyond choosing mode `uri` when the target contains a
scheme-looking prefix (the server already knows this because it is choosing
between forms per RFC 9112, typically via the method or by sniffing the first
byte for `/` vs ALPHA vs `*`).

### authority-form (`CONNECT host:port`)
**Missing** — none of uriparse's three modes parses bare `host:port` as an
authority. All three modes route a `:` in the leading token to "this is a
scheme", because `example.com` alone matches the `scheme` ABNF
(`ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )`) and byte-machine cannot look past
the colon before committing (this is exactly decision 0018's forward-only
argument, restated for authority-form). Measured, three ways:
```
authority-form as 'uri (misparse expected): mode=uri input="example.com:443"
  scheme="example.com"
  authority=<absent>
  path="443"
  query=<absent>
  fragment=<absent>

authority-form as 'relative-ref (error expected): mode=relative-ref input="example.com:443"
  ERROR code=scheme-forbidden offset=11

authority-form as 'uri-reference (mode 3): mode=uri-reference input="example.com:443"
  scheme="example.com"
  authority=<absent>
  path="443"
  query=<absent>
  fragment=<absent>
```
`scheme-forbidden` is raised at the grammar's `path-nc-first` node
(`src/uri/grammar.sls:168-175`, specifically the `COLON` case at `:171`
`(rex 'e-scheme-forbidden)`) — mode 2 refuses on principle, modes 1 and 3
silently misparse `example.com` as a scheme and `443` as a path. **None of the
three modes is correct for authority-form.**

**Working workaround, measured**: prepend `//` and parse with `relative-ref`.
This routes through `hier-slash1` (`grammar.sls:145-149`) into `auth-open`
(`:154-156`), which opens the (undifferentiated) `authority` span over the
whole `host:port` (or `[IPv6]:port`) and closes it cleanly at EOF, present
but empty path:
```
authority-form via //prefix hack: mode=relative-ref input="//example.com:443"
  scheme=<absent>
  authority="example.com:443"
  path=""
  query=<absent>
  fragment=<absent>

authority-form IPv6 via //prefix hack: mode=relative-ref input="//[::1]:8080"
  scheme=<absent>
  authority="[::1]:8080"
  path=""
  query=<absent>
  fragment=<absent>
```
This is the smallest working path today, but it is a caller-side trick uriparse
documents nowhere, and the server still gets an **opaque `authority`
bytevector** — see item 4/8 for host:port splitting, which uriparse does not
do at all yet.

### asterisk-form (`OPTIONS *`)
**Accidentally present**, not specially recognized. `*` (byte 42) is a
`sub-delim` (`src/uri/charset.sls:45` `(fx=? b 42)` in `sub-delim?`), hence a
legal `pchar`, hence legal path content, so `relative-ref` mode's
`path-nc-first`/`path-scan` nodes (`grammar.sls:168-175`,`160-166`) simply
treat a bare `*` as a one-byte path segment:
```
asterisk-form (relative-ref): mode=relative-ref input="*"
  scheme=<absent>
  authority=<absent>
  path="*"
  query=<absent>
  fragment=<absent>
```
uriparse gives you back `path = "*"`; it has no idea this is the reserved
OPTIONS-only literal. **The server must special-case `request-target == "*"`
itself** (and reject it for any method other than OPTIONS, and reject any
*other* target for OPTIONS `*`-form ambiguity) — this is pure server logic,
not something uriparse can help with, and not something worth feeding through
`uri-parse` at all (it is one byte compared against a literal).

**Where the redundant/needed work already happens for free**: chez-httparse's
*main* message parser already resolves the CONNECT-vs-everything-else split
during ordinary request-line parsing, with **zero extra parsing cost** to the
server, because it splices `(httparse url-grammar)`'s subgraph into the
request line and branches on the already-parsed `method` field
(`chez-httparse/src/httparse/grammar.sls:1053-1064`,
`make-field-branch-node 'url-which-entry 'equal (list 'method (method-number
"CONNECT")) 'url-entry-connect 'url-entry-normal`). It even structurally
rejects a non-CONNECT authority-form target inline (comment at
`grammar.sls:1073-1076`: `OPTIONS a.com:443 HTTP/1.1` "reads `a.com` as a
schema, wants `//` after the colon, and errors"). See item 7 for how this
should be used instead of duplicating form-detection logic in uriparse calls.

---

## 2. Percent-decoding for routing, and dot-segment removal against path traversal

**Both present**, but as two *separate* functions the server must chain
correctly, and the one uriparse ships for "decode the path" is the wrong one
to reach for by itself.

- `(uri percent) pct-decode` (`src/uri/percent.sls:80-96`) is a **full**,
  single-pass percent-decoder: every valid `%XX` becomes its octet regardless
  of reserved/unreserved status. This is what a router wants for path
  comparison against literal route segments.
- `(uri normalize) pct-normalize` (`src/uri/normalize.sls:74-95`) is
  **selective**: it only decodes a `%XX` when the resulting octet is
  §2.3-unreserved (`unreserved-byte?`, `src/uri/percent.sls:64-68`); every
  other valid triple is kept encoded but re-rendered uppercase. Since `.`
  (0x2E) **is** unreserved, this is the function that turns `%2e%2e` into
  literal `..` — which is exactly what `(uri path) remove-dot-segments`
  (`src/uri/path.sls:158-163`) needs to see to do its job. `remove-dot-segments`
  itself is byte-literal: it matches `"."`/`".."`/`"./"`/`"../"` etc. verbatim
  (`path.sls:121-139`) and has **no percent-encoding awareness at all** (the
  library doc says so explicitly: "A path is opaque bytes here" and
  "non-validating: every byte string is a path", `path.sls:8-14`).

**Consequence for a static-file handler**: calling `remove-dot-segments`
directly on the *raw* parsed path is not enough to stop
`%2e%2e/%2e%2e/etc/passwd`; the server must run `pct-normalize` (not raw
`pct-decode`, though `pct-decode` also works here since `.` decodes to `.`
regardless) over the path **first**. This chaining is not spelled out anywhere
in uriparse's docs — `.plans/2026-09-18-chez-uri-design.md` only notes M5
"CREATES" dot-segments and "M6 resolves a normalized path, never a raw one"
(design doc line ~72-73) as a resolve-time concern, not as a security
requirement for routing. Measured, `scratchpad/uriparse-probe/probe2.sps`:
```
plain traversal input="/../../etc/passwd"
  raw path="/../../etc/passwd"
  normalized path (pct-normalize)="/../../etc/passwd"
  after remove-dot-segments="/etc/passwd"

mixed traversal input="/a/b/../../../etc/passwd"
  raw path="/a/b/../../../etc/passwd"
  normalized path (pct-normalize)="/a/b/../../../etc/passwd"
  after remove-dot-segments="/etc/passwd"

pct-encoded dot traversal (%2e%2e) input="/a/%2e%2e/%2e%2e/etc/passwd"
  raw path="/a/%2e%2e/%2e%2e/etc/passwd"
  normalized path (pct-normalize)="/a/../../etc/passwd"
  after remove-dot-segments="/etc/passwd"

double-encoded dot traversal (%252e%252e) input="/a/%252e%252e/etc/passwd"
  raw path="/a/%252e%252e/etc/passwd"
  normalized path (pct-normalize)="/a/%252e%252e/etc/passwd"
  after remove-dot-segments="/a/%252e%252e/etc/passwd"

uppercase pct-encoded dot (%2E%2E) input="/a/%2E%2E/etc/passwd"
  raw path="/a/%2E%2E/etc/passwd"
  normalized path (pct-normalize)="/a/../etc/passwd"
  after remove-dot-segments="/etc/passwd"
```
Two good properties fell out of this, both worth recording for
chez-http-server's design: (1) excess `..` above the path root does **not**
error or escape — `drop-last-segment` (`path.sls:100-102`) is a no-op on an
already-empty output buffer, so `/a/b/../../../etc/passwd` clamps to
`/etc/passwd` rather than climbing past root or crashing; (2) the codec's
"do not decode more than once" single-pass rule (`percent.sls:76-79`,
enforced by advancing 3 bytes past a decoded triple rather than rescanning)
means a **double**-encoded traversal attempt (`%252e%252e`) is *not* unwrapped
into `..` by one call to `pct-normalize` — it stays inert. A server that
naively decoded to a fixed point would be vulnerable here; uriparse's design
protects against that by construction, not by the server remembering to loop
once.

---

## 3. Query splitting into key/value pairs and form-urlencoded decoding

**Missing, and explicitly out of scope forever, not merely deferred.**
`.plans/2026-09-18-chez-uri-project-brief.md:315-317` (the "Out of scope, and
say so in a decision record" section):

> **`application/x-www-form-urlencoded`** query splitting. RFC 3986's `query`
> is opaque; `key=value&...` is an HTML convention. `chez-http-server` will
> want it — put it in a clearly separate module, or in the server, and do not
> let it into the URI grammar.

Confirmed empty at the source level: no function named anything like
`query-pairs`, `split-query`, or `form-urlencoded` exists anywhere under
`src/` (`rg -in "query-pair|form-urlencoded|split.*query" src/` — zero hits,
run this session). `uri-parse` gives you the raw `query` bytevector only,
verbatim between `?` and `#`/EOF:
```
query bytes for a=1&b=2: "a=1&b=2&c"
```
(`scratchpad/uriparse-probe/probe2.sps` output, mode `relative-ref`, input
`/x?a=1&b=2&c`). **chez-http-server must write its own `&`/`=` splitter and
its own `+`-to-space, percent-decode-per-pair logic** (form-urlencoded's
`+`-means-space rule is not RFC 3986 percent-decoding at all —
`(uri percent) pct-decode` does not touch `+`, which is correct for §3.4
`query` but wrong for form-urlencoded without an extra pass). This is a
deliberate, documented boundary — not a bug to report upstream, and not
something to wait on. It should land as a small standalone module in
chez-http-server (or a fourth sibling library), operating on the `query`
bytevector uriparse already hands back.

---

## 4. Host grammar validation (deferred to v0.2) — impact on Host header validation

**Missing entirely**, more thoroughly than the README's one-line caveat
suggests. The `authority` component is one **opaque, uninterpreted span** at
every layer:

- Scanner: "There is deliberately no authority span [sub-]structure ...
  userinfo/host/port are the CORE's" (`.plans/2026-09-18-chez-uri-design.md`
  §3.1, and restated at `src/uri/vocabulary.sls:17-21,82-85`,
  `src/uri/grammar.sls:9-15,151-153`).
- Charset validator (M3, already shipped): **excludes authority on
  purpose**. `(uri charset) component-bytes` in `src/uri/collect.sls:200-205`
  has cases only for `scheme`/`path`/`query`/`fragment`; there is no
  `authority` arm, and `validate-result` (`collect.sls:213-227`) only loops
  over `'(scheme path query fragment)` (`:215`). `src/uri/charset.sls:5-7`
  says this outright: "PORT and every authority-interior charset (userinfo,
  host, reg-name, IP-literal) are M4's — the authority is one opaque span
  until then."
- Normalizer: "the authority case is left ALONE (host-case is M4/v0.2)"
  (`src/uri/normalize.sls:19-24,101-102`) — so even scheme-style lowercasing
  never touches the host.

**Empirically confirmed that even `uri-parse-validate` (the M3 "judge the
charsets" entry point) passes a garbage authority through untouched**,
`scratchpad/uriparse-probe/probe3.sps`:
```
space in host, via uri-parse-validate (M3) input="http://exa mple.com/"
  ACCEPTED authority="exa mple.com"
control char CR in host input="http://exa\rmple.com/"
  ACCEPTED authority="exa\rmple.com"
malformed IPv6 host (no closing bracket) input="http://[::1/x"
  ACCEPTED authority="[::1"
host with illegal byte and valid path/query/fragment input="http://ho<>st/ok?ok#ok"
  ACCEPTED authority="ho<>st"
```
The CR case is the one that matters most for an HTTP server: **uriparse will
hand back an authority/Host bytevector that itself contains a bare CR**, with
no error and no offset, if the raw bytes contained one syntactically inside
the authority position. (The README says as much in the abstract — "It will
accept bytes the ABNF rejects: `http://exa mple.com/`" — but does not call out
the CR/CTL case, which is the one with response-splitting / header-injection
consequences if that value is later echoed into a redirect `Location` header
or a log line without the server's own check.)

**Consequence for chez-http-server**: until v0.2's host grammar (M4) ships,
the server cannot rely on uriparse for *any* Host-header well-formedness
check — not "is this a legal `reg-name`", not "is this a legal `IP-literal`",
not even "does this contain a byte an HTTP header value must never contain".
The server needs its own minimal authority/Host validator (at minimum: reject
CTL, SP, and — separately, since Host is also an HTTP header value — the usual
header-injection bytes) as a stopgap. `README.org:37-40` and decision
`0020-v01-normalizes-scheme-and-percent-and-defers-host-case.md` both document
the *absence* accurately; this is not a case of the prose being wrong (per the
task's warning about that), it just undersells how completely unchecked the
authority bytes are today.

---

## 5. The bytevector-in/bytevector-out API, and absent-vs-empty

**Present, and load-bearing** — this is the one area where uriparse is
unusually well-suited to routing. `(uri components)` (`src/uri/components.sls`)
is five fields, each **either a bytevector or `#f`**, enforced at
construction (`check-field`, `components.sls:45-51`, raising
`&uri-components` if a string or anything else slips in). `#f` is absent;
`(make-bytevector 0)` is present-and-empty; the two are never conflated
(`uri-component-absent?`/`uri-component-empty?`, `components.sls:68,76-77`).
This distinction is not incidental — RFC 3986 §5.3 recomposes on `defined()`,
not on non-emptiness (design doc §3.2, `2026-09-18-chez-uri-design.md:132-149`),
so a type that merged the two "could not implement §5" (`components.sls:14-16`).

Why it matters for routing specifically, verified in
`scratchpad/uriparse-probe/probe.sps`:
```
empty authority http:///p: mode=uri input="http:///p"
  scheme="http"
  authority=""
  path="/p"
  query=<absent>
  fragment=<absent>

no authority http:/p: mode=uri input="http:/p"
  scheme="http"
  authority=<absent>
  path="/p"
  query=<absent>
  fragment=<absent>
```
`http:///p` (empty authority, i.e. `Host: ` with a real but empty value) and
`http:/p` (no authority at all) are **distinguishable** through uriparse's
`#f`-vs-`(bytevector 0)` fields — a server that needs to tell "the client sent
an explicit empty Host" from "there was never an authority position" (e.g. to
decide whether a 400 is warranted per RFC 9112's Host-header rules) can do so
directly off `uri-components-authority`. Query works the same way: present
routing code doing `(and (uri-component-present? q) ...)` correctly
distinguishes `/p?` (empty-but-present query) from `/p` (no query) without any
extra bookkeeping.

**One caveat for the server's data model**: because the type is
`Bytevector | #f` and nothing else (`components.sls:40-44`), any place
chez-http-server threads a `uri-components` value through Scheme code that
expects `""` as its absent-marker (rather than `#f`) will break at
construction time with a clear `&uri-components` condition rather than
silently misbehaving — worth keeping in mind when the server's own request
struct is designed, but not a defect in uriparse.

---

## 6. Performance / allocation of `uri-parse` per request

**No allocation budget or benchmark ships with uriparse** — decision
`0016-there-is-no-allocation-lane.md` states this is deliberate ("Not
deferred — not wanted", `:22`) and pushes the allocation *property* onto
byte-machine's own retention lane (`:24-30`), explicitly declining to assert
a per-parse budget because "it would be a number chosen to pass ... and its
failures would be indistinguishable from a noisy runner" (`:50-56`). So there
is **no upstream number to cite**; I measured one instead.

Measured on this machine (Chez 10.4.1, tarm64osx, `--libdirs "src:
vendor/byte-machine/src"`), `scratchpad/uriparse-probe/bench2.sps` and
`bench3.sps` and `bench4.sps`, each run with `(collect-request-handler
(lambda () (void)))` set immediately before the timed loop so an
auto-triggered GC mid-loop cannot make `bytes-allocated` go negative (it did,
the first time — see `bench.sps`'s raw output below, kept as evidence of the
methodology problem and its fix):
```
$ chez --libdirs "src:vendor/byte-machine/src" --script bench.sps   # WITHOUT disabling GC
iterations: 200000
elapsed ms: 261
bytes allocated total: -352368        <- a GC fired mid-loop; discard this run
```
```
$ chez --libdirs "src:vendor/byte-machine/src" --script bench2.sps  # 200000 iters, 66-byte origin-form target
iterations: 200000
elapsed ms: 325
ns/parse: 1625.0
bytes allocated total: 753349440
bytes/parse: 3766.7472
```
```
$ chez --libdirs "src:vendor/byte-machine/src" --script bench3.sps  # isolates make-uri-collector alone, no feed/finish
construct-only ns/call: 900.0
construct-only bytes/call: 2133.6568
```
```
$ chez --libdirs "src:vendor/byte-machine/src" --script bench4.sps  # size scaling: 2-byte vs ~610-byte target
short (2 bytes) ns/parse: 1420.0
short (2 bytes) bytes/parse: 3362.0016
long (~610 bytes) ns/parse: 2820.0
long (~610 bytes) bytes/parse: 5204.6576
```
**Finding**: roughly **55-65% of `uri-parse`'s allocation, and over half its
wall time, is fixed per-call overhead that has nothing to do with the input's
length** — constructing a fresh `make-parser` (a new byte-machine parser
record plus its callback-binding table) and two fresh `eq-hashtable`s
(`table`, `offsets` in `src/uri/collect.sls:134-135`) inside
`make-uri-collector`, every single call. `uri-parse` (`collect.sls:190-193`)
always calls `make-uri-collector` fresh; there is **no reset/reuse path**
exposed — the collector's message dispatch
(`collect.sls:173-182`) only understands `'feed!` and `'finish!`, and after
`'finish!` the closure's mutable state (`table`, `offsets`, `present`,
`rooted?`, `verdict`) is not rewound, so even a caller willing to hand-roll
reuse has no supported way to get back to a clean parser — the parser itself
would need `parser-reset!` (which byte-machine's runtime exports, per the
design doc's library table) plumbed through, and the three accumulator
hashtables cleared, none of which `(uri collect)` offers.

At roughly 1.4-2.8 microseconds and 3.3-5.2 KB per call for realistic
request-target sizes, this is not alarming in isolation — it's in the same
order of magnitude as a single small heap allocation elsewhere in a request's
lifecycle — but for a server parsing one request-target per request under
load, "most of the cost is a parser object nobody asked to keep" is a real,
fixable inefficiency, not an inherent cost of URI splitting. See item 8 for
the concrete ask.

---

## 7. Relationship to chez-httparse's own url sub-parser — which to use for what, and redundancy

chez-httparse ships **two** URL-related things, and it is worth being precise
about which is which, because only one of them is a candidate for
"redundant with uriparse":

1. **The main HTTP message parser's `on-url-data`/`on-url-complete`**
   (`chez-httparse/src/httparse/grammar.sls:727-728,756`). This delivers the
   whole request-target as **one opaque span** — no splitting — but as of
   chez-httparse's decision 0023 (referenced at `grammar.sls:1068-1069`) it
   is no longer a dumb byte-accumulator: llhttp's own URL machine is spliced
   in with `separateSpans = false` (stub part-spans, one whole `url-span`)
   and, critically, **branches on the already-parsed HTTP method** to pick
   its entry point (`grammar.sls:1053-1064`,
   `make-field-branch-node 'url-which-entry 'equal (list 'method
   (method-number "CONNECT")) 'url-entry-connect 'url-entry-normal`). So
   the *form* selection RFC 9112 asks for (authority-form only for CONNECT,
   general form otherwise) **already happens for free**, at zero extra
   parsing cost, inside ordinary request-line parsing — and a target that is
   structurally wrong for the method it was sent with (`OPTIONS a.com:443`)
   is **already rejected**, per the worked example in the source comment at
   `grammar.sls:1073-1076`. What you get out of it is one byte range and a
   yes/no on "is every byte in it `URL_CHAR` (or the CONNECT-host set), no
   illegal char stopped it, exactly one delimiter ended it" — no percent
   decoding, no component split, no dot-segment removal, no resolve/recompose.

2. **The separate `(generated httparse-url)` / `httparse-url-machine`**
   (`chez-httparse/src/httparse/url-grammar.sls`, documented in
   `docs/api.org` under "The url sub-parser", lines ~231-267 read this
   session). This is llhttp's URL binary rebuilt with `separateSpans = true`:
   five span callbacks (`on-url-schema-data`, `on-url-host-data`,
   `on-url-path-data`, `on-url-query-data`, `on-url-fragment-data`), **no
   percent-decoding**, and — the key limitation for chez-http-server's
   purposes — `on-url-host-data` "carries the *whole* authority — userinfo,
   host and port together, brackets and all" (`docs/api.org` "What it does
   not split" section, and `url-grammar.sls:254`,`:342-343`
   comments). It *does* have a CONNECT-aware entry (`url-entry-connect`,
   `url-grammar.sls:256,278-287`) and does peek `*` into the path span at
   `url-start` (`url-grammar.sls` around the `url-node c 'url-start` case,
   read this session — `/` and `*` both open the path span on the
   delimiter). It also has two documented rough edges worth flagging if the
   server ever reaches for it: it re-enters at its own start on every SP/CR/LF
   (so `/path /next` in one buffer yields two independent url-spans,
   `docs/api.org` "Two edges worth knowing"), and a host ending at `?` keeps
   the `?` in the host span (`span[url.host]="host.com?"`, same section) —
   both stated as upstream (llhttp) behavior, reproduced rather than fixed.

**Where the redundancy actually is, and the recommendation**: (1) is not
redundant with uriparse — it is strictly cheaper, already running, and its
job (structural sanity + CONNECT/general form selection) is exactly the part
of item 1 uriparse cannot do at all. (2) genuinely **overlaps** uriparse:
both split scheme/authority-ish/path/query/fragment out of the same bytes,
neither validates the authority's interior (userinfo/host/port,
`docs/api.org` "What it does not split" vs. uriparse's M4/v0.2 deferral,
item 4 above), and neither percent-decodes the host. Running *both* per
request would be pure waste. **chez-http-server should use (1)'s
`on-url-data` span only to get the raw target bytes and the free
CONNECT-vs-general structural check, and hand those bytes to uriparse's
`(uri collect)` for everything downstream** (component split with the
absent/empty distinction, percent handling, dot-segment removal, and later
resolve/recompose) — never reach for (2) at all in the server's hot path.
The one thing (2) has that uriparse structurally lacks is llhttp's
`URL_CHAR` charset check (which is *stricter* about the authority's bytes
than uriparse's charset validator, which per item 4 checks it not at all)
and its CONNECT-aware entry; both of those are already available for free
from (1) without invoking (2) as a second full parser.

---

## 8. What's missing for a server, and the smallest upstream change

Summarizing the gaps found above, ranked by how much they cost
chez-http-server to work around itself, with the smallest fix that would
remove each:

1. **Authority-form (CONNECT `host:port`) has no correct mode.** Smallest
   upstream fix: a fourth scanner mode (or a `uri-parse` keyword) that opens
   `authority` directly at offset 0 with no `//` and no scheme — mechanically
   identical to prepending `//` (item 1's measured workaround), so this could
   ship as a **pure-Scheme convenience wrapper in `(uri collect)`** (e.g.
   `uri-parse-authority-form : Bytevector -> uri-parse-result`, implemented
   by literally splicing a two-byte `//` prefix and re-mapping the resulting
   offsets) with **no grammar/byte-machine change at all** — the cheapest
   possible fix, and one chez-http-server could even carry itself as a local
   helper without waiting on uriparse.
2. **No host:port (or userinfo:host:port) split.** This is squarely M4/v0.2,
   already scoped in the project brief (`.plans/2026-09-18-chez-uri-project-
   brief.md:282-291`: `reg-name`, `IPv4address`, `IP-literal` →
   `IPv6address`/`IPvFuture`, with the IPv6 node-count estimate at 150-250
   nodes, generated programmatically). Nothing to ask for beyond "ship M4" —
   it is on uriparse's own roadmap, not a gap in their plan, just not built
   yet. Until then chez-http-server needs its own byte-level
   `userinfo@host:port` / `[IPv6]:port` splitter, operating on the opaque
   `authority` bytevector uriparse already hands back (item 4).
3. **No authority/Host charset validation at all** (item 4) — including no
   rejection of CTL/CR bytes inside the authority. This is the one gap with
   security relevance today (potential header-injection surface if the
   server threads an unvalidated Host value into a response header or log).
   Smallest mitigating change: a single new `(uri charset)` case for
   `authority` that rejects at minimum `SP`/CTL bytes (not the full host
   grammar — just "an HTTP header value must never contain these") would
   close the sharpest edge without waiting for the complete M4 host grammar;
   short of that, chez-http-server needs its own pre-check on the raw
   `authority` bytevector before using it as a Host value anywhere
   header-adjacent.
4. **No form-urlencoded query splitting** (item 3) — by design, explicitly
   out of scope forever, not a gap to file upstream. chez-http-server should
   write its own small module over the `query` bytevector.
5. **`(uri collect)` has no way to reuse a parser/collector across calls**
   (item 6) — `uri-parse` allocates a fresh `make-parser` plus two fresh
   `eq-hashtable`s every call, and roughly 55-65% of the per-call cost is
   this fixed overhead rather than proportional-to-input work. Smallest
   upstream change: export a `uri-collector-reset!` that calls byte-machine's
   `parser-reset!` (already in `(byte-machine runtime)`'s exports per the
   design doc's library table) and clears the three mutable fields
   (`table`, `offsets`, `present`, `rooted?`, `verdict`) in place, so a
   server that owns one collector per worker/connection can parse many
   request-targets without re-allocating the parser and its hashtables each
   time. This is additive (a new exported procedure) and does not change
   `uri-parse`'s existing one-shot behavior.
6. **IDNA / RFC 3987 IRI handling** — explicitly, permanently out of scope
   per the project brief (`.plans/2026-09-18-chez-uri-project-brief.md:318`:
   "RFC 3987 IRIs, IDNA, Punycode, Unicode mapping tables"). Not a gap to
   raise upstream at all. If chez-http-server ever needs to compare a
   Unicode `Host:` header against an ASCII/Punycode-registered vhost, that
   is server-side (or a separate, explicitly-scoped library) work, by
   uriparse's own design decision — raising it upstream would be asking them
   to reverse a recorded decision, not report a bug.

---

## Empirical scaffolding

All Scheme probes are kept under this task's scratchpad for reproducibility:

- `scratchpad/uriparse-probe/probe.sps` — the four request-target forms
  (section 1), the `//`-origin-form ambiguity, empty-vs-absent authority
  (section 5).
- `scratchpad/uriparse-probe/probe2.sps` — percent-decoding/dot-segment
  chaining and traversal cases (section 2), raw query bytes (section 3).
- `scratchpad/uriparse-probe/probe3.sps` — `uri-parse-validate` accepting
  illegal authority bytes, including a bare CR (section 4).
- `scratchpad/uriparse-probe/bench.sps`, `bench2.sps`, `bench3.sps`,
  `bench4.sps` — allocation/timing measurements (section 6), including the
  discarded first attempt that shows why `collect-request-handler` had to be
  neutralized before measuring.

Run from `/Users/yuzu/github/uriparse` with:
```
chez --libdirs "src:vendor/byte-machine/src" --script <probe>.sps
```
