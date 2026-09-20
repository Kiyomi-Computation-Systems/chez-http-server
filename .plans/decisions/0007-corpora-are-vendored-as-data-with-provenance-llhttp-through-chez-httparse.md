# 0007: Corpora are vendored as data with provenance; llhttp is reached through chez-httparse; libhtp's streams come first

Date: 2026-09-19
Status: accepted
Plan: [test corpus survey](../2026-09-19-test-corpus-survey.md)

## Context

79 candidates were surveyed and 72 verified by two skeptics each. chez-httparse already vendors llhttp with per-file sha256 and a `PROVENANCE`, and its harness libraries are pure R6RS. libhtp's 102 `test/files/*.t` streams (BSD-3-Clause) are the only found corpus whose files carry explicit packet boundaries and cover exactly the connection semantics the parser corpus cannot: pipelining, multi-packet heads, CONNECT, HTTP/0.9, Expect, timeouts, smuggling shapes. The repository is archived, so the files will not move under us.

## Decision

1. llhttp fixtures are not copied into this repository; the corpus lane imports chez-httparse's loader, chunker, trace recorder and comparator.
2. Every other vendored set lives under `test/vendor/<name>/` with `LICENSE`, `PROVENANCE` (URL, ref, commit, retrieval date, sha256 per file) and a `make corpus-refresh` target that re-fetches and re-checksums; vendored bytes are never edited.
3. Order: libhtp `.t` (M1), Kestrel `HttpParsingData` tables (M2), httpd `http_strict.t` and lighttpd `request.t` cases (M2), smuggling payload sets (M8). Cowboy's suites, Go's tests, Netty's and h11's are scenario sources, copied as our own rows with a comment naming the origin, not vendored.
4. GPL-licensed material (HAProxy reg-tests, http-garden, HTTPWookiee, siege) is used only as an external tool or by reference.
5. A ratchet manifest names every fixture in every lane with its status; a fixture changing status in either direction fails the lane until reviewed.

## Consequences

- The corpus lane's `pr` preset runs the `extremes` chunk sizes; `release` runs every size, as chez-httparse does.
- Our expectations for libhtp files are ours (the `<<<` chunks are a recorded origin's responses, not an oracle), written per file and mutation-witnessed.
