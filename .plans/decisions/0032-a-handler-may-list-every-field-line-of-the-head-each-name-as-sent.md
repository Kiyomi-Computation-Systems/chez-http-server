# 0032: A handler may list every field line of the head, each name as sent

Date: 2026-10-25
Status: accepted (user decision, 2026-10-25: the owner's issue #214, picked up with
"pickup issue 214")
Plan: none; the issue is the design

## Context

- A handler reads a field it can name, by `request-header` and `request-header-values`
  (decision 0024), but cannot list them. A handler that logs a request, proxies it or
  hands its headers on as a map cannot see a field it does not know by name.
- circuit, a Ring-like layer over the server, builds a headers list for every request it
  hands an app. At v0.8.0 its only way reaches past the facade: `request-headers` from
  `(http-server request)`, which answers spans, `(http-server span)` to read them, and
  `(http-server headers)`'s `trim-ows`. docs/reference.md documents none of the three, so
  nothing holds them across releases. Decision 0024 weighed the same road for
  chez-websocket and did not take it: "no promise across versions".
- The core keeps every field line of the head in the request, in the order it came: each
  completed value joins the head's fields, which are reversed when the request is made.
  Trailers are not part of the request.

## Decision

1. **`request-header-list : Request -> (Listof (Pair String String))`**, in
   `(http-server view)` and exported by the facade:
   - every field line of the head, in the order it came;
   - the name as sent, in its own case, a character per byte, as the other accessors
     read;
   - the value as `request-header` gives it, without the whitespace around it;
   - a name on several lines comes as several pairs;
   - made when called, as the other accessors are, so a handler that does not call it
     pays nothing.
2. **The name** completes the family `request-header`, `request-header-values`. It is not
   `request-headers`: `(http-server request)` exports that name, with spans.

## Consequences

- No wire change. RFC 9110 §5.1 makes names case-insensitive, so a caller that compares
  them folds case itself; §5.3 makes the order of lines with the same name significant,
  and the list keeps it.
- `tests/test-view.sps` holds the order, the names, the values and the repeated names
  through the real core and parser, and
  `tests/test-serve.sps` the facade's exports. Seven mutants each failed the view suite:
  names folded to lower case, values left untrimmed, the order reversed, the first line
  dropped, values read as UTF-8, and only the first line of each name kept, matched with
  and without regard to case.
- circuit can drop its workaround; its probe goes red once the facade exports the name.
- **Weighed and not taken:**
  - documenting `(http-server request)`, `(http-server span)` and `(http-server headers)`
    as public: three libraries' shapes promised, and a span pins its whole delivery;
  - names folded to lower case, as Ring gives them: what was sent is lost, a caller folds
    cheaply, and the other accessors give what was sent;
  - one pair a name, its lines joined: the order across names is lost, and how to join is
    the caller's, as chez-websocket's handshake chose for itself (decision 0024).
