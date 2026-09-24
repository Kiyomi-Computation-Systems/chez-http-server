# 0009: A browser's unencoded bracket params and pipes are redirected with a 301; every other invalid target is refused with 400

Date: 2026-09-24
Status: accepted (user decision, 2026-09-24)
Plan: [the milestone plan](../2026-09-20-chez-http-server-milestone-plan.md) §6, M2.3

## Context

M2.3 judges every request-target against RFC 9112 §3.2's four forms, with uriparse's audited RFC 3986 validators (the ledger's M2.3 entry; decision 0002's amendments of 2026-09-24). The core answers a target those validators refuse with 400, and the connection closes.

**llhttp is more lenient on purpose.**
- Its URL table admits every printable ASCII byte except space, `#` and `?`. The table sits in `src/llhttp/constants.ts` under the comment "TODO(indutny): use RFC".
- When Node 12 moved to llhttp, requests with `|` in the query started failing with 400 from Chrome (nodejs/node#27584). llhttp's corpus now pins `|` as allowed, citing that issue (`request/uri.md`, "Query URL with vertical bar character").

**The reason is browsers.** The WHATWG URL standard, which browsers implement, percent-encodes less than RFC 3986 requires:
- in a query: only C0 controls, space, `"`, `#`, `<` and `>`, plus `'` for http and https;
- in a path: those, plus `?`, `^`, backtick, `{` and `}`.

So a link, a `fetch()` or a typed URL sends `[`, `]` and `|` unencoded, and in a query `{`, `}`, `\`, `^` and backtick too. Tomcat has been strict about these bytes since CVE-2016-6816, and added its `relaxedPathChars` and `relaxedQueryChars` settings for the same reason.

The targets that matter in practice are bracket params (PHP and Rails style, `?ids[]=1`, `?user[name]=x`) and pipes (`?markers=red|blue`, `/files/a|b.txt`). chez-httparse parses them, but uriparse's validators refuse them, so a strict core answers every such link 400.

RFC 9112 §3.2 gives a recipient of an invalid request-line two choices: a 400, or a 301 redirect to the request-target properly encoded.

## Decision

1. **A refused target is redirected instead** when all of these hold:
   - the method is GET or HEAD. A client may turn a POST into a GET when it follows a 301 (RFC 9110 §15.4.2);
   - the target is origin-form, and its path does not begin `//`. A Location that began `//` would be a network-path reference, which a client resolves to another host, so the server would be an open redirect. Browsers also read `\` in a path as `/`, so `/\host` is `//host` in disguise. No Location ever carries `\`, because the next rule refuses any target that still has another fault;
   - its only faults are `|` in the path, and `[`, `]` or `|` in the query;
   - the target with those bytes percent-encoded is one the core accepts: valid, different from the target, and within `max-target-bytes`. The encoding is uriparse's `pct-encode`: `[` becomes `%5B`, `]` `%5D` and `|` `%7C`, in uppercase hex.
2. **The answer is `301 Moved Permanently`**, with `Location` set to the encoded target and no body. The Location is an absolute-path reference, which the client resolves against the URI it asked for (RFC 9110 §10.2.2).
3. **The connection closes after it**, as after every status the core originates (design §6.5). Its close reason is `target-redirect`. The core stops the parser at `on-headers-complete`, so nothing after the head is read.
4. **Every other invalid target still gets 400.** That covers:
   - `"`, `<`, `>`, `{`, `}`, `\`, `^` and backtick;
   - brackets in a path;
   - a malformed `%`;
   - a fragment, or userinfo;
   - `*` with a method other than OPTIONS, or a CONNECT target that is not `host:port`;
   - any refused target in a request whose method is not GET or HEAD.

## Consequences

- A browser that follows a bracket-param or pipe link gets one redirect and then the page. The handler only ever sees a valid target, the encoded one.
- A 301 can be cached by heuristic (RFC 9110 §15.4.2), so a browser may go straight to the encoded URL next time. That is intended: the encoded URL names the same resource.
- `(http-server target)` exports `target-redirect`. The core keeps the Location in the head until the parser's error arrives, and `reason-status` answers `target-redirect` with 301. By this record, design §6.5's table of originated statuses gains a `301` row.
- The trace lane's property 1 now lists the llhttp fixture `request/uri.md#5` (`GET /test.cgi?query=|`) as a redirect. It was a listed 400 before.
- Letting more bytes through later (braces, backslash, caret, backtick) is a change to one set in `target-redirect`, with a test per byte. Widening the redirect beyond GET and HEAD would need 308, not 301.
- Tests: `tests/test-target.sps` holds the rules, and `tests/test-connection-head.sps` drives them end to end through the parser. Mutations M2.3-O to X are in `.superpowers/sdd/m2-mutations.md`.
- Users read about it in `docs/request-targets.org`.
