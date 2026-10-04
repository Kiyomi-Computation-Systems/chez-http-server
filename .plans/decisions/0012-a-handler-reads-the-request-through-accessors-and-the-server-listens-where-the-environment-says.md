# 0012: A handler reads the request through accessors that copy what it asks for; the server listens where CHEZ_HTTP_HOST and CHEZ_HTTP_PORT say

Date: 2026-09-26
Status: accepted (user decision, 2026-09-26)
Plan: [the milestone plan](../2026-09-20-chez-http-server-milestone-plan.md) §8, M4 (M4.5, re-planned in the ledger)

## Context

M4's exit needs a server that curl and ab can reach, so M4 adds the facade,
`(http-server)`, as M4.5 (decision 0001's layout names it; no slice held it). Two
things it must settle were in no plan or decision.

- **What a handler sees.** The core builds the request from spans: the target and
  each header's name and value are the bounds of the bytes in the delivery the shell
  read, never copied (design §7.1, decision 0002's second amendment). That is half
  of how a request costs 1,840 B through the parser, adapter and core against the
  3,072 B ratchet (the M3 exit). M2.2 left the handler's view to M4.
- **Where the server listens.** Every setting so far is a `CHEZ_HTTP_` variable
  read by the shell (decision 0005's amendment of 2026-09-20). Hosting platforms
  (Heroku, Cloud Run, Render, Fly) set `PORT`.

Measured by `research/spike/m4-handler-view.sps` (2026-09-26, Darwin arm64, Chez
10.4.1; two identical runs): the bytes a view adds per request, beyond what parser,
adapter and core cost.

| request | accessors: the path and one header | every request copied to strings first | the spans alone |
|---|---|---|---|
| curl's GET, 3 fields | 80 | 416 | 0 |
| a JSON POST, 5 fields | 96 | 720 | 0 |
| a browser's GET, 11 fields | 192 | 1,872 | 0 |

The JSON POST is gated at 3,072 B and costs 2,384 B through the core, so copying
every request first would put it at 3,104 B.

## Decision

1. **A handler reads the request through accessors that copy what it asks for.** The
   facade gives the path, the query, a header's value by name, and the host as
   strings, each made when asked, and the method as the symbol llhttp names. The
   spans stay the request's: a handler that keeps one keeps its delivery too, up to
   `read-buffer-size` bytes (design §7.1).
2. **The host follows RFC 9112 §3.2.2.** For an absolute-form target the host is the
   target's authority, whatever the Host field says (an origin server MUST ignore
   it); otherwise it is the Host field's value, which may be empty.
3. **The server listens where `CHEZ_HTTP_HOST` and `CHEZ_HTTP_PORT` say**, read by the
   shell with the limits, defaulting to `127.0.0.1` and `8080`: loopback, so a server
   is exposed only when asked. A container sets `CHEZ_HTTP_HOST=0.0.0.0`.

The alternatives weighed: for the view, every request copied to strings before the
handler runs, or the spans alone, which every handler would copy itself; for the
address, the same variables defaulting to `0.0.0.0`, or the platforms' `PORT` beside
`CHEZ_HTTP_HOST`.

## Consequences

- A handler that reads nothing costs nothing. The allocation gate measures parser,
  adapter and core, and no view is added to it.
- `docs/` says the rule a span brings: bytes a handler keeps past its call should be
  copied, or they keep their delivery.
- An empty Host on an origin-form request is served, and the host reads empty: RFC
  9112 §3.3 lets a server reject it or apply a configured default, and v1 has no
  default to apply. Whether to serve an absolute-form target of another scheme,
  such as `ftp:`, is the handler's routing, as any path is.
- A deployment platform that sets only `PORT` maps it to `CHEZ_HTTP_PORT` in its
  launcher.

## Amendment (2026-09-27) — what the accessors read (M4.5)

Settled in M4.5 where this record is silent, and kept on the owner's word ("Go with
the recommendations"). `tests/test-view.sps` holds each.

- A string is a character per byte (Latin-1), as this record's measurement made its
  strings, so every byte reads back as it was sent. Nothing is percent-decoded.
- The query is what follows the target's first "?", in every form. A "?" can be in
  neither an authority nor a path (RFC 3986 §3.2, §3.3).
- The path by form: origin-form's up to the first "?"; an absolute-form target's
  URI path, "/" when it is empty (RFC 9110 §4.2.3); "*" for asterisk-form; "" for
  authority-form.
- A header's value is its first field's, by name in any case, without the whitespace
  around it (RFC 9112 §5). llhttp keeps the whitespace after a value, so the view
  trims where it reads, as the Host judge and the transfer-coding reader do.
  Trimming once, where the core records a value, can come later as a change of its
  own.
- A CONNECT request's host is the Host field's, by this record's letter. RFC 9112
  §3.3 would read the target, the tunnel's destination, but v1 answers a CONNECT and
  closes, so no handler needs it.
- An absolute-form target's host and path cost a uriparse parse each time they are
  asked for: 3,904 B, measured on curl's GET in absolute-form (Darwin arm64). The
  cost is accepted, as CONNECT's fresh parse is (design §7.5): absolute-form is a
  proxy's, rare at an origin server, and a handler that does not ask pays nothing.

## Amendment (2026-10-04) — a value is trimmed where it is read

Decided on the owner's word on 2026-10-04 ("close it"), after a discussion of the
amendment above: trimming once, where the core records a value, will not come. A value
stays recorded as it arrived, and each reader trims it.

- **No reader misses the trim.** Two readers take a value whole and trim it: the view,
  behind `request-header` and `request-host`, a handler's only way to read a value, and
  the Host judge. Three read a value as a list, Expect, Upgrade and Transfer-Encoding,
  and trim each element, as they must, since whitespace may sit around any comma. The
  facade exports no span, so a handler never sees a value untrimmed.
- **Trimming where a value is read allocates nothing.** `trim-ows` moves the bounds,
  and a field nobody reads is never trimmed.
- **Trimming where the core records a value costs every field a check,** and a new span
  for each value that ends in whitespace, since spans are immutable. M4's probe of it
  (HW-P, progress.md) kept every suite green, the allocation lane included: the cost is
  the hot path's, not the tests'.
- **RFC 9110 §5.5 is met where a value is evaluated.** It has the whitespace excluded
  before a field value is evaluated, and each reader excludes it before it evaluates. A
  future reader of a whole value calls `trim-ows`, as the Host judge does.

Plan §14's open list drops the item.
