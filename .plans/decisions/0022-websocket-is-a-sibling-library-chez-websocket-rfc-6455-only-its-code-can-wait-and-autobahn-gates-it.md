# 0022: WebSocket is a sibling library, chez-websocket: RFC 6455 only, its code can wait, and Autobahn gates it

Date: 2026-10-04
Status: accepted (user decision, 2026-10-04, by form: "New repo", "Can wait", "RFC 6455
only", "Autobahn in CI"; then "Create it now")
Plan: [the milestone plan](../2026-09-20-chez-http-server-milestone-plan.md) §15

## Context

After v0.2.0 the owner asked to "begin the websocket path". Plan §9's note of 2026-09-26,
written after the owner asked whether WebSocket support belongs in this server or in a
library above it, records that "WebSocket is a library of its own that takes a stream
through the door, not code in this repository (0001 items 3 and 4)". Decision 0016 built
that door: a handler answers `switch-protocols`, the server writes the 101, and a taker
is handed a transport. A taker's code runs in place, in the shell's callbacks, and cannot
`await` (0016's consequences).

Read 2026-10-04, each with its source:
- **RFC 6455**, read from `mnot/rfc-refs`'s copy (`rfcs/rfc6455.txt`, the same bytes as
  three other copies; rfc-editor.org's page cuts off for the reader used):
  - the server checks the handshake (§4.2.1). It answers `Sec-WebSocket-Accept`, the
    base64 of the SHA-1 of the key and a GUID (§4.2.2); its example key
    `dGhlIHNhbXBsZSBub25jZQ==` gives `s3pPLMBiTxaQ9kYGzzhZRbK+xOo=`;
  - a client's frames MUST be masked (§5.1), and a length MUST use its shortest
    encoding (§5.2);
  - control frames carry at most 125 bytes and are never fragmented (§5.5);
  - a close is answered with a close (§5.5.1), the server closing TCP first (§7.1.1),
    and codes 1005, 1006 and 1015 are never sent (§7.4.1);
  - text MUST be valid UTF-8, the connection failed with 1007 if not (§5.6, §8.1);
  - limits SHOULD be capped (§10.4), and a server meant for particular sites SHOULD
    check `Origin`, answering 403 (§10.2).
- **RFC 7692** §5: a server declines permessage-deflate by leaving it out of its 101.
- **Peers**, at the versions read (source files and lines in the session's research):
  - Python websockets 17.2, Go's coder/websocket v1.8.15 and gorilla/websocket v1.5.3,
    and Rust's tungstenite 0.30.0 read a message with a call that waits; Node's ws
    8.22.0 delivers it to a callback.
  - Their default message caps run from 32 KiB (coder) to none (gorilla).
  - Only coder and gorilla check `Origin` by default.
  - Only websockets compresses by default; its docs give about 64 KiB a connection with
    compression on, 14 KiB off.
- **Autobahn|Testsuite** (`crossbario/autobahn-testsuite`, Apache-2.0, pushed
  2026-09-29, tag v25.10.1):
  - 517 cases in its case registry: 301 without the permessage-deflate cases (12.x and
    13.x), and 247 without 9.x as well.
  - Its image `crossbario/autobahn-testsuite:25.10.1`, digest
    `sha256:519915fb568b04c9383f70a1c405ae3ff44ab9e35835b085239c258b6fac3074`, is
    linux/amd64 only.
  - A run exits with no failure status, so the projects that run it gate on its
    `index.json`. Deno pins the tag and digest, and accepts OK, NON-STRICT and
    INFORMATIONAL.
- **Here:**
  - an idle connection holds about 20 KB (`CHANGELOG.md`'s `[0.1.0]`), and a parked
    `await` 3,637 to 3,644 B (design §5.2);
  - neither SHA-1 nor base64 exists in the tree or its dependencies;
  - Docker 29.2.1 runs on the development Mac (arm64).

## Decision

By form, the recommended answer to each of four questions:

1. **A sibling library of its own, `chez-websocket`.** It is private, BSD 3-Clause and on
   `main`, as the siblings are. It holds a pure protocol core (the handshake, frames,
   the close and UTF-8, bytes in and actions out) and a binding over this server's
   transport, and it pins chez-http-server at a release tag. On "Create it now" the
   repository was made on 2026-10-04 (`Kiyomi-Computation-Systems/chez-websocket`), its
   first commit the siblings' license (27ad906).
2. **Its code can wait.** A WebSocket handler reads with a call that waits for the next
   message, as four of the five peers read. The door gains that here first (decision
   0023), released as server 0.3.0.
3. **v1 is RFC 6455 alone**: permessage-deflate is declined, as RFC 7692 §5 allows, and
   there is no client.
4. **Autobahn gates it**, in Linux CI, its image pinned by digest and each case's result
   held by a ratchet: 301 cases without compression.

## Consequences

- This repository's part is the door change (0023) and its release. Everything else is
  chez-websocket's, planned in its own brief, design and plan.
- The new repository's CI reads chez-http-server and its four private dependencies, so
  the owner's read token must reach them.
- Caddy passes `Origin` on unchecked (plan §9's note): chez-websocket's handshake
  decides what it accepts, in a slice of its own.
- Weighed and not taken:
  - the library in this repository, which would reverse plan §9's note and 0016's "a
    library of its own";
  - callbacks in place, which need no server change but leave message code unable to
    wait;
  - permessage-deflate, which is DEFLATE both ways in pure Scheme and 216 more Autobahn
    cases;
  - a client;
  - unit vectors alone, with no black-box check.
