# The development container scripts/docker-env runs: ci.yml's linux job as
# an image, for a host without the toolchain.
#
# The Chez version arrives as a build arg scripts/docker-env reads from
# ci.yml's CHEZ_FLOOR_VERSION, so the floor is stated in one place.
FROM ubuntu:24.04

ARG CHEZ_VERSION
RUN test -n "$CHEZ_VERSION" || { echo "build-arg CHEZ_VERSION is required" >&2; exit 1; }

# ci.yml's toolchain step, package for package, and ca-certificates, which
# a runner has and git and curl need: `make submodules`, `make oha` and
# `make site-deps` fetch over https.
RUN apt-get update -qq \
 && apt-get install -y --no-install-recommends \
      build-essential cmake pkg-config libuv1-dev \
      libx11-dev libncurses-dev uuid-dev git \
      curl apache2-utils libpcre2-dev zlib1g-dev python3 cmark-gfm \
      ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# apt's chezscheme is below the floor, so Chez is built from its release
# tag, as ci.yml builds it.
RUN git clone --depth 1 --branch "v${CHEZ_VERSION}" \
      https://github.com/cisco/ChezScheme.git /tmp/ChezScheme \
 && cd /tmp/ChezScheme \
 && ./configure --threads --installprefix=/usr/local \
 && make -j"$(nproc)" \
 && make install \
 && rm -rf /tmp/ChezScheme

# The installed binary is `scheme`; the Makefile's CHEZ defaults to `chez`.
# No `chez` symlink: Chez finds its boot files by the name it runs as.
ENV CHEZ=scheme

# The container runs as the host user's uid, which may own no entry here,
# and the host's file sharing may show the checkout as another's. git
# refuses a repository it judges another user's, so it trusts every one.
RUN git config --system --add safe.directory '*'
