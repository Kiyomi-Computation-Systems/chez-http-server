# 0028: the docs site renders through chez-cmark-gfm, pinned by Akku.lock as chez-libuv's does

Date: 2026-10-16
Status: accepted (user decision, 2026-10-16, by form: "Akku.lock, as chez-libuv" and "A step in the linux job (Recommended)")
Plan: none; the docs site follows the Markdown rewrite of `docs/`

## Context

`docs/` is seventeen Markdown pages, home first (`docs/README.md`), in the shape of
chez-libuv's and chez-httparse's. Both render theirs to a static site with a small
Scheme generator (`build-site.sps`, `site/*.sls`) through chez-cmark-gfm, which binds
the system libcmark-gfm and needs no Scheme library at run time. The generator is
ported from chez-libuv's, whose home page is `docs/README.md` as ours is.

Global constraints: "Dependencies are pinned checkouts by gitlink at release tags …
No other dependencies without a decision record."

The peers get chez-cmark-gfm three ways:
- **chez-libuv**: `Akku.lock` pins the archive by sha256 (`depends/dev` in its
  `Akku.manifest`). `make site-deps` uses an `akku install` tree when there is one,
  else `scripts/fetch-akku-lock` downloads the locked archive, checks its sha256 and
  unpacks it to `build/akku/`. `tests/fetch-akku-lock.sh` tests the script offline.
- **chez-httparse**: `CMARK_GFM_ROOT` names a checkout; nothing is pinned.
- **Every other dependency here**: a submodule at a release tag.

Measured 2026-10-16, on Darwin arm64 (an Apple M1, Homebrew cmark-gfm 0.29.0.gfm.13):
- **The archive.** `chez-cmark-gfm_2.0.0_repack.tar.xz` is 403,224 B, fetched in
  0.87 s, sha256 `bb647e07…8305159`, the sum Akku's index records for it.
- **A submodule instead.** A clone of chez-cmark-gfm is 4.1 MB, made in 0.5 s; its
  v2.0.0 tag is 3c84828.
- **The lock.** `akku lock` (Akku 1.1.1-beta.0), for a manifest whose one dependency
  is `(depends/dev ("chez-cmark-gfm" "2.0.0"))`, wrote a lock naming that archive and
  sum alone. `akku install` from that lock, with no manifest beside it, installed
  `.akku/lib/cmark/gfm.sls`.
- **The site.** v2.0.0, from the archive and from the tag's checkout alike, renders all
  seventeen pages (148,622 B of HTML) in 0.26 to 0.28 s through `make site`. The three
  check programs take 0.16 to 0.18 s each, and the fetch script's offline test 0.67 s.

## Decision

1. **`Akku.lock` pins chez-cmark-gfm 2.0.0's archive by sha256**, for the docs site
   alone. It is `akku lock`'s output for the one-dependency manifest above. There is no
   `Akku.manifest`: chez-http-server is not an Akku package, and a manifest naming
   only a development dependency would describe one without its runtime dependencies.
2. **`make site-deps` gets it as chez-libuv's does**: from `.akku/lib` after `akku
   install`, else through `scripts/fetch-akku-lock` into `build/akku/`, refusing an
   archive whose sha256 is not the lock's. A second run needs no network.
   `make check-site-deps` runs `tests/fetch-akku-lock.sh`, offline.
3. **`make site` renders `docs/*.md` into `build/site/`**; `SITE_REF` pins links to
   repository files (`../examples/*.sps`) to a git ref, `main` by default.
4. **`make check-site` runs the generator's two suites, then renders `docs/` in
   memory** and fails on a page missing from the nav or the nav naming a file `docs/`
   lacks, a link or anchor that resolves to nothing, a relative `.md` link left in the
   HTML, a relative link to a file the site does not write, a link to a repository
   file the checkout lacks, a heading whose anchor GitHub spells differently, and a
   reflowed `<pre>`.
5. **None of it is in `make test`.** Nothing under `src/` and no `tests/test-*.sps`
   imports chez-cmark-gfm, so the suite needs neither the archive nor libcmark-gfm.
6. **CI runs `make check-site-deps` and `make check-site`** in the linux job, after
   the suite, with apt's `cmark-gfm`.

## Consequences

- A docs page that links a missing page or anchor fails CI before merge.
- Moving chez-cmark-gfm is a new lock: `akku lock` for the same manifest at the new
  version, and the fetched tree is replaced whole on the next `make site-deps`.
- The site needs libcmark-gfm on the machine that builds it; the server does not.
