# Installing

chez-http-server is a set of R6RS libraries. You build its one native piece,
chez-libuv's small C *shim*, once on each machine with `make build`. Then you
put five folders on Chez's library path and import `(http-server)`.

It runs on macOS and Linux, on x86-64 and arm64. Windows is not supported
yet: chez-libuv, the libuv binding it runs on, does not support it.

## What you need

- **Chez Scheme 10.4.1 or newer, threaded.** Threaded is Chez's default
  build. The examples here call the binary `chez`; yours may be `scheme`.
- **libuv 1.48 or newer**, where `pkg-config` can see it:
  `brew install libuv` on macOS, `apt install libuv1-dev` on Ubuntu 24.04 or
  newer. With no libuv, or an older one (Debian 12 has 1.44), the build
  compiles a copy pinned in chez-libuv instead, which needs CMake 3.10 or
  newer.
- **A C compiler and `make`.**

To build and try the server without installing these, use a container:
`scripts/docker-env` with Docker, or `scripts/guix-env` on a Guix host,
runs a command in one that has all of it. Put it before `make build` and
`make run` below, as in `scripts/docker-env make build`. For Docker,
`make run` also needs `-p 8080` before it, so that `curl` can reach the
server. Using the server from your own project still needs the list. See
[In Docker](building.md#in-docker) and
[On a Guix host](building.md#on-a-guix-host).

## Build it

```sh
git clone --recursive https://github.com/Kiyomi-Computation-Systems/chez-http-server.git
cd chez-http-server
make build
```

`--recursive` fetches the dependencies, which are pinned git submodules
under `vendor/`: chez-libuv, chez-httparse (with byte-machine inside it),
uriparse, and, for the tests, chez-srfi and vtest2. `make build` compiles the
shim and prints the library path it uses.

Check it works:

```sh
make run PROGRAM=examples/hello.sps
```

Then, in another terminal, `curl http://127.0.0.1:8080/` answers `Hello`.
Press Ctrl-C to stop it.

## Use it from your own project

Put these five folders of the checkout on `CHEZSCHEMELIBDIRS`, separated by
colons:

| Folder                                    | Holds                          |
|:------------------------------------------|:-------------------------------|
| `src`                                     | the server, `(http-server)`    |
| `vendor/chez-libuv/src`                   | `(libuv)`, the event loop      |
| `vendor/chez-httparse/src`                | the HTTP parser                |
| `vendor/chez-httparse/vendor/byte-machine/src` | the parser's runtime      |
| `vendor/uriparse/src`                     | the URL validator              |

For a checkout at `~/src/chez-http-server`:

```sh
H=~/src/chez-http-server
export CHEZSCHEMELIBDIRS="$H/src:$H/vendor/chez-libuv/src:$H/vendor/chez-httparse/src:$H/vendor/chez-httparse/vendor/byte-machine/src:$H/vendor/uriparse/src"
chez --program my-server.sps
```

A common setup is to add chez-http-server to your own repository as a git
submodule, pinned to a release tag, and set the path in your `Makefile`.

## Check the pins

`make check-pins` checks that every submodule sits at the commit this
release was tested with. Run it after you pull, or after moving a submodule.

## Next

- [Quickstart](quickstart.md): write a first server.
- [Building and testing](building.md): run the test suite.
