---
name: Bug report
about: Something broke or behaved unexpectedly
labels: bug
---

<!-- A suspected vulnerability? Don't file it here: SECURITY.md says how to
report it privately. -->

**Environment**

- OS and architecture (e.g. macOS 15 arm64, Ubuntu 24.04 x86_64):
- Chez Scheme version (`chez --version`):
- libuv version (`pkg-config --modversion libuv`, or "built by chez-libuv"):
- chez-http-server version or commit:

**What happened**

**What you expected**

**How to reproduce it**

Ideally a small handler and the request that shows it: the raw bytes, or the
`curl` command. A program runs with `make run PROGRAM=repro.sps`.

**Does `make test` pass on your machine?**
