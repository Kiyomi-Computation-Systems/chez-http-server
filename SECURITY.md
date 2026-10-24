# Security Policy

## Supported versions

| Version | Supported |
|---|---|
| The latest release (see [CHANGELOG.md](CHANGELOG.md)) | ✅ |
| Earlier releases | ❌ |

## Reporting a vulnerability

Please report suspected vulnerabilities privately via GitHub:
**Security → Report a vulnerability** on this repository. Do not open a
public issue.

You can expect an acknowledgement within 7 days.

This server faces the network, so these reports are especially welcome:

- request smuggling or desync: a request whose framing it reads
  differently from a proxy or another server;
- a request it serves that it should refuse;
- a limit or timeout a client can get around;
- memory a client can make it hold, or a way to stop it serving others.

Please include your platform, Chez version, libuv version, and the bytes of
a request that shows it, or the client and the steps.

A report about a dependency (chez-libuv, chez-httparse, uriparse or
byte-machine) is welcome here too.
