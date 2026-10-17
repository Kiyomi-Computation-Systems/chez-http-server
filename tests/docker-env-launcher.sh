#!/bin/sh
# Host-side tests for scripts/docker-env. Nothing here runs Docker: each
# case runs a copy of the launcher in a fake tree, with a fake `docker`
# first on PATH that logs every call, one argument per line, and a `----`
# line after each. So whether this checkout is a worktree changes nothing,
# and the image build is tested along with the run.
#
# `make check-docker` runs this before the container's own checks. Checks
# name themselves, and the exit status is non-zero if any failed.
#
# Single-quoted dollar signs here are literal on purpose: they check that
# `$HOME` and the like pass through unexpanded.
# shellcheck disable=SC2016
set -u

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
launcher=$root/scripts/docker-env

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

pass=0
fail=0

ok()    { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad()   { fail=$((fail + 1)); printf 'FAIL %s\n' "$1" >&2; }
check() { name=$1; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
err_lines() { tr '\n' '|' <"$tmp/err"; }

# The fake docker. `image inspect` finds the image only when
# FAKE_DOCKER_HAVE is set; `version` reaches the daemon unless
# FAKE_DOCKER_DOWN is set; `build` and `run` exit with
# FAKE_DOCKER_BUILD_STATUS and FAKE_DOCKER_RUN_STATUS, 0 by default.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/docker" <<'EOF'
#!/bin/sh
{ printf '%s\n' "$@"; echo ----; } >>"$FAKE_DOCKER_LOG"
case "$1" in
  image) [ -n "${FAKE_DOCKER_HAVE:-}" ] ;;
  version) [ -z "${FAKE_DOCKER_DOWN:-}" ] ;;
  build) echo "fake build output"; exit "${FAKE_DOCKER_BUILD_STATUS:-0}" ;;
  run) exit "${FAKE_DOCKER_RUN_STATUS:-0}" ;;
  *) exit 99 ;;
esac
EOF
chmod +x "$tmp/bin/docker"
log=$tmp/docker.log

# calls: how many times docker ran. call N: the Nth call's arguments,
# joined by |.
calls() { n=$(grep -cx -- ---- "$log" 2>/dev/null); echo "${n:-0}"; }
call() {
  awk -v n="$1" '$0 == "----" { i++; next } i == n - 1 { printf "%s|", $0 }' "$log"
}

# The fake HOME has a space and a non-ASCII letter in it, and holds the
# kinds of credential a developer's HOME does. The container must receive
# none of them.
home="$tmp/fake hôme"
mkdir -p "$home/.ssh"
: >"$home/.ssh/id_ed25519"
: >"$home/.gitconfig"

# Fake trees live under a path with a space, a comma and a quote in it:
# docker's --mount reads its fields as CSV.
trees="$tmp/tr ees, \"q\""

# tree DIR: a copy of the launcher at DIR/scripts/docker-env, a Dockerfile,
# and a ci.yml naming the Chez floor, so that DIR is the root it computes.
tree() {
  mkdir -p "$1/scripts" "$1/docker" "$1/.github/workflows"
  cp "$launcher" "$1/scripts/docker-env"
  printf 'FROM scratch\n' >"$1/docker/dev.Dockerfile"
  printf 'env:\n  CHEZ_FLOOR_VERSION: "10.4.1"\n' >"$1/.github/workflows/ci.yml"
}

main=$trees/main
tree "$main"
mkdir -p "$main/.git/worktrees/out" "$main/.git/worktrees/in" \
  "$main/.git/worktrees/rel" "$main/.git/worktrees/abs"
: >"$main/.git/HEAD"
for w in out in rel; do printf '../..\n' >"$main/.git/worktrees/$w/commondir"; done
printf '%s\n' "$main/.git" >"$main/.git/worktrees/abs/commondir"

# worktree DIR GITDIR: a linked worktree at DIR whose .git file names GITDIR.
worktree() {
  tree "$1"
  printf 'gitdir: %s\n' "$2" >"$1/.git"
}

# run [VAR=value...] LAUNCHER [ARG...]
# Runs from $cwd in a scrubbed environment, the fake docker first on PATH.
# stdout -> $tmp/out, stderr -> $tmp/err, exit -> $status; the fake
# docker's calls -> $log, emptied first.
cwd=$main
run() {
  status=999
  : >"$log"
  ( cd "$cwd" && env -i HOME="$home" PATH="$tmp/bin:$PATH" FAKE_DOCKER_LOG="$log" \
      SSH_AUTH_SOCK="$home/ssh-agent.sock" GH_TOKEN=fake-token "$@" ) \
    >"$tmp/out" 2>"$tmp/err"
  status=$?
}

user="$(id -u):$(id -g)"

# mnt DIR: the --mount value that binds DIR at the same path inside, its
# fields CSV-quoted with any quote doubled.
mnt() {
  q=$(printf '%s' "$1" | sed 's/"/""/g')
  printf 'type=bind,"source=%s","target=%s"' "$q" "$q"
}

# run_cmd ROOT IMAGE [EXTRA...] -- CMD...: the whole docker run call, joined
# by |. EXTRA comes after the defaults and before the image. With $share
# set, a second --mount binds it after the checkout's.
share=
run_cmd() {
  r=$1 img=$2; shift 2
  printf 'run|--rm|--interactive|--init|--user|%s|--mount|%s|' "$user" "$(mnt "$r")"
  [ -z "$share" ] || printf -- '--mount|%s|' "$(mnt "$share")"
  printf -- '--workdir|%s|--env|HOME=/tmp|--env|TERM|--env|COLORTERM|--env|LANG|' "$r"
  while [ "$1" != -- ]; do printf '%s|' "$1"; shift; done
  shift
  printf '%s|' "$img" "$@"
}

# The image's name: the Chez floor, then a checksum of the Dockerfile and
# the floor.
tag_re='^chez-http-server-dev:10\.4\.1-[0-9][0-9]*$'
is_tag() { printf '%s\n' "$1" | grep -Eq "$tag_re"; }

# ---- the image ----

# T1: with no image, the launcher checks the daemon answers, builds the
# image, on stderr, then runs an interactive bash in it from the
# repository's root.
run "$main/scripts/docker-env"
check "T1 exits 0" [ "$status" -eq 0 ]
check "T1 four docker calls" [ "$(calls)" -eq 4 ]
image=$(sed -n '3p' "$log")
check "T1 looks for the image first" [ "$(call 1)" = "image|inspect|$image|" ]
check "T1 the image is named for the Chez floor" is_tag "$image"
check "T1 then asks the daemon" [ "$(call 2)" = "version|--format|{{.Server.Version}}|" ]
check "T1 builds docker/dev.Dockerfile with the floor from ci.yml" \
  [ "$(call 3)" = "build|--build-arg|CHEZ_VERSION=10.4.1|--tag|$image|--file|docker/dev.Dockerfile|docker|" ]
check "T1 the build's output goes to stderr" grep -Fxq "fake build output" "$tmp/err"
check "T1 stdout holds nothing of the build" [ ! -s "$tmp/out" ]
check "T1 the whole run command" [ "$(call 4)" = "$(run_cmd "$main" "$image" -- bash)" ]
# Written out by hand, not by mnt: each field quoted, each quote doubled.
check "T1 the checkout's --mount, CSV-quoted" grep -Fxq -- \
  "type=bind,\"source=$tmp/tr ees, \"\"q\"\"/main\",\"target=$tmp/tr ees, \"\"q\"\"/main\"" "$log"

# T2: with the image present, it runs without building.
run FAKE_DOCKER_HAVE=1 "$main/scripts/docker-env" make test
check "T2 image present: two docker calls" [ "$(calls)" -eq 2 ]
check "T2 image present: no build" [ "$(call 2)" = "$(run_cmd "$main" "$image" -- make test)" ]
check "T2 image present: says nothing" [ ! -s "$tmp/err" ]

# T3: a failed build is reported, and nothing runs.
run FAKE_DOCKER_BUILD_STATUS=1 "$main/scripts/docker-env" make test
check "T3 failed build: exit 2" [ "$status" -eq 2 ]
check "T3 failed build: no run" [ "$(calls)" -eq 3 ]
check "T3 failed build: says so" grep -Fq "docker-env: building $image failed" "$tmp/err"

# T3b: with no image and no daemon (Docker not started), the launcher says
# so, and neither builds nor runs.
run FAKE_DOCKER_DOWN=1 "$main/scripts/docker-env" make test
check "T3b no daemon: exit 2" [ "$status" -eq 2 ]
check "T3b no daemon: says why" \
  [ "$(err_lines)" = "docker-env: cannot reach the Docker daemon; start Docker and try again|" ]
check "T3b no daemon: no build, no run" [ "$(calls)" -eq 2 ]

# T4: the image's name follows the Dockerfile and the floor, and nothing
# else, so a change to either builds a new image and the same inputs reuse
# one.
run FAKE_DOCKER_HAVE=1 "$main/scripts/docker-env" true
same=$(sed -n '3p' "$log")
check "T4 same inputs, same image" sh -c '[ -n "$1" ] && [ "$1" = "$2" ]' sh "$same" "$image"
printf 'RUN true\n' >>"$main/docker/dev.Dockerfile"
run "$main/scripts/docker-env" true
edited=$(sed -n '3p' "$log")
check "T4 an edited Dockerfile names another image" \
  sh -c '[ "$1" != "$2" ]' sh "$edited" "$image"
check "T4 that name is an image's" is_tag "$edited"
check "T4 that image is built" [ "$(calls)" -eq 4 ]
printf 'FROM scratch\n' >"$main/docker/dev.Dockerfile"
printf 'env:\n  CHEZ_FLOOR_VERSION: "10.5.0"\n' >"$main/.github/workflows/ci.yml"
run "$main/scripts/docker-env" true
check "T4 a new floor names another image" \
  sh -c 'printf "%s\n" "$1" | grep -Eq "^chez-http-server-dev:10\.5\.0-[0-9]+$"' sh "$(sed -n '3p' "$log")"
check "T4 and builds it at that floor" grep -Fxq CHEZ_VERSION=10.5.0 "$log"
printf 'env:\n  CHEZ_FLOOR_VERSION: "10.4.1"\n' >"$main/.github/workflows/ci.yml"

# T5: a ci.yml naming no floor is refused, and docker never runs.
printf 'env:\n  OTHER: "1"\n' >"$main/.github/workflows/ci.yml"
run "$main/scripts/docker-env" make test
check "T5 no floor: exit 2" [ "$status" -eq 2 ]
check "T5 no floor: says why" \
  [ "$(err_lines)" = "docker-env: .github/workflows/ci.yml names no CHEZ_FLOOR_VERSION|" ]
check "T5 no floor: no docker call" [ "$(calls)" -eq 0 ]
printf 'env:\n  CHEZ_FLOOR_VERSION: "10.4.1"\n' >"$main/.github/workflows/ci.yml"

# T6: no docker on PATH is refused, saying so.
mkdir -p "$tmp/nodocker"
for t in sh sed cat cksum cut id dirname awk; do
  ln -s "$(command -v "$t")" "$tmp/nodocker/$t"
done
status=999
( cd "$main" && env -i HOME="$home" PATH="$tmp/nodocker" "$main/scripts/docker-env" make test ) \
  >"$tmp/out" 2>"$tmp/err"
status=$?
check "T6 no docker: exit 2" [ "$status" -eq 2 ]
check "T6 no docker: says so" \
  [ "$(err_lines)" = "docker-env: docker not found on PATH; install Docker, or use scripts/guix-env on a Guix host|" ]

# ---- the run ----

# T7: arguments pass through verbatim, spaces and dollars included, and
# the run's exit status is the launcher's.
run FAKE_DOCKER_HAVE=1 FAKE_DOCKER_RUN_STATUS=7 "$main/scripts/docker-env" make "a b" '$HOME'
check "T7 args pass through verbatim" \
  [ "$(call 2)" = "$(run_cmd "$main" "$image" -- make "a b" '$HOME')" ]
check "T7 the run's exit status" [ "$status" -eq 7 ]

# T8: nothing from HOME, and no agent socket or token, enters the
# container; it mounts the checkout and nothing else.
for args in "sh scripts/docker-env-selftest" ""; do
  # shellcheck disable=SC2086
  run FAKE_DOCKER_HAVE=1 "$main/scripts/docker-env" $args
  label=${args:-no-args}
  check "T8 [$label] one mount" [ "$(grep -cx -- --mount "$log")" -eq 1 ]
  check "T8 [$label] nothing from HOME" sh -c '! grep -Fq -- "$1" "$2"' sh "$home" "$log"
  check "T8 [$label] no agent socket" sh -c '! grep -Fq SSH_AUTH_SOCK "$1"' sh "$log"
  check "T8 [$label] no token" sh -c '! grep -Fq GH_TOKEN "$1"' sh "$log"
  check "T8 [$label] no port published" sh -c '! grep -Fq -- --publish "$1"' sh "$log"
done

# T9: launched by relative path from a subdirectory, the container still
# starts in the repository's root.
mkdir -p "$main/sub"
cwd=$main/sub
run FAKE_DOCKER_HAVE=1 ../scripts/docker-env make help
cwd=$main
check "T9 subdirectory: exits 0" [ "$status" -eq 0 ]
check "T9 subdirectory: the root's mount and workdir" \
  [ "$(call 2)" = "$(run_cmd "$main" "$image" -- make help)" ]

# T10a: --tty only when stdin and stdout are both a terminal. Each case
# runs under util-linux `script`, which gives the launcher one, with stdin
# or stdout sent elsewhere; elsewhere `script` takes other options, and
# these are skipped.
if script --version 2>/dev/null | grep -q util-linux; then
  cat >"$tmp/tty-run.sh" <<'EOF'
#!/bin/sh
cd "$TTY_MAIN" || exit 99
set -- env -i HOME="$TTY_HOME" PATH="$TTY_PATH" FAKE_DOCKER_LOG="$TTY_LOG" \
  FAKE_DOCKER_HAVE=1 ./scripts/docker-env true
case "$TTY_MODE" in
  both) "$@" ;;
  stdin) "$@" >/dev/null ;;
  stdout) "$@" </dev/null ;;
esac
EOF
  for mode in both stdin stdout; do
    : >"$log"
    TTY_MAIN=$main TTY_HOME=$home TTY_PATH="$tmp/bin:$PATH" TTY_LOG=$log TTY_MODE=$mode \
      script -qec "sh $tmp/tty-run.sh" /dev/null </dev/null >/dev/null 2>&1
    if [ "$mode" = both ]; then
      check "T10a a terminal on both ends: --tty" grep -Fxq -- --tty "$log"
    else
      check "T10a a terminal on $mode alone: no --tty" sh -c '[ -s "$1" ] && ! grep -Fxq -- --tty "$1"' sh "$log"
    fi
  done
else
  printf 'skip T10a: no util-linux script to give the launcher a terminal\n'
fi

# ---- -p PORT ----

# T10: -p PORT publishes PORT on the host's loopback only, and has the
# server listen on every address inside, on that port.
for port in 8080 3000 1 65535; do
  run FAKE_DOCKER_HAVE=1 "$main/scripts/docker-env" -p "$port" make run PROGRAM=x.sps
  check "T10 -p $port: exit 0" [ "$status" -eq 0 ]
  check "T10 -p $port: the whole run command" \
    [ "$(call 2)" = "$(run_cmd "$main" "$image" --publish "127.0.0.1:$port:$port" \
      --env CHEZ_HTTP_HOST=0.0.0.0 --env "CHEZ_HTTP_PORT=$port" -- make run PROGRAM=x.sps)" ]
done

# T11: -p with no command opens the shell, with the port.
run FAKE_DOCKER_HAVE=1 "$main/scripts/docker-env" -p 8080
check "T11 -p alone: bash, published" \
  [ "$(call 2)" = "$(run_cmd "$main" "$image" --publish 127.0.0.1:8080:8080 \
    --env CHEZ_HTTP_HOST=0.0.0.0 --env CHEZ_HTTP_PORT=8080 -- bash)" ]

# T12: -p anywhere but first belongs to the command.
run FAKE_DOCKER_HAVE=1 "$main/scripts/docker-env" make -p
check "T12 a later -p is the command's" [ "$(call 2)" = "$(run_cmd "$main" "$image" -- make -p)" ]

# T13: a port that is not one is refused, saying why, and docker never runs.
for port in 0 65536 99999999999999999999 08080 abc 80a '' -1 '8 0'; do
  run "$main/scripts/docker-env" -p "$port" make test
  check "T13 -p '$port': exit 2" [ "$status" -eq 2 ]
  check "T13 -p '$port': says why" \
    [ "$(err_lines)" = "docker-env: -p takes a port from 1 to 65535, not '$port'|" ]
  check "T13 -p '$port': no docker call" [ "$(calls)" -eq 0 ]
done
run "$main/scripts/docker-env" -p
check "T13 -p with nothing after: exit 2" [ "$status" -eq 2 ]
check "T13 -p with nothing after: says why" \
  [ "$(err_lines)" = "docker-env: -p takes a port from 1 to 65535|" ]
check "T13 -p with nothing after: no docker call" [ "$(calls)" -eq 0 ]

# ---- linked worktrees ----

# T14: a linked worktree outside the main checkout also mounts the main
# repository's .git, the common directory, and only that.
wt_cmd() {  # ROOT SHARED
  share=$2 run_cmd "$1" "$image" -- make test
}
worktree "$trees/out" "$main/.git/worktrees/out"
cwd=$trees/out
run FAKE_DOCKER_HAVE=1 "$trees/out/scripts/docker-env" make test
check "T14 worktree outside: exit 0" [ "$status" -eq 0 ]
check "T14 worktree outside: the whole command" \
  [ "$(call 2)" = "$(wt_cmd "$trees/out" "$main/.git")" ]

# T15: one inside the main checkout's tree, as `.claude/worktrees/` puts
# them, still needs it: the container mounts only the worktree.
worktree "$main/.claude/worktrees/in" "$main/.git/worktrees/in"
cwd=$main/.claude/worktrees/in
run FAKE_DOCKER_HAVE=1 "$main/.claude/worktrees/in/scripts/docker-env" make test
check "T15 worktree inside main: the whole command" \
  [ "$(call 2)" = "$(wt_cmd "$main/.claude/worktrees/in" "$main/.git")" ]

# T16: a relative gitdir (worktree.useRelativePaths) resolves from the
# worktree's root, and an absolute commondir is taken as it is.
worktree "$trees/rel" "../main/.git/worktrees/rel"
cwd=$trees/rel
run FAKE_DOCKER_HAVE=1 "$trees/rel/scripts/docker-env" make test
check "T16 relative gitdir: mounts the common directory" \
  [ "$(call 2)" = "$(wt_cmd "$trees/rel" "$main/.git")" ]
worktree "$trees/abs" "$main/.git/worktrees/abs"
cwd=$trees/abs
run FAKE_DOCKER_HAVE=1 "$trees/abs/scripts/docker-env" make test
check "T16 absolute commondir: mounts the common directory" \
  [ "$(call 2)" = "$(wt_cmd "$trees/abs" "$main/.git")" ]

# T17: a separate git directory (`git init --separate-git-dir`) has no
# commondir: the git directory itself is mounted. One inside the tree is
# mounted already, and adds nothing.
mkdir -p "$trees/separate-git"
: >"$trees/separate-git/HEAD"
worktree "$trees/sep" "$trees/separate-git"
cwd=$trees/sep
run FAKE_DOCKER_HAVE=1 "$trees/sep/scripts/docker-env" make test
check "T17 separate git dir: mounts it" \
  [ "$(call 2)" = "$(wt_cmd "$trees/sep" "$trees/separate-git")" ]
mkdir -p "$trees/own/.real-git"
: >"$trees/own/.real-git/HEAD"
worktree "$trees/own" ".real-git"
cwd=$trees/own
run FAKE_DOCKER_HAVE=1 "$trees/own/scripts/docker-env" make test
check "T17 git dir inside the tree: one mount" [ "$(grep -cx -- --mount "$log")" -eq 1 ]
check "T17 git dir inside the tree: exit 0" [ "$status" -eq 0 ]

# T18: a .git file the launcher cannot follow is refused, naming it, and
# docker never runs.
refused() {  # LABEL TREE EXPECTED-STDERR
  cwd=$2
  run FAKE_DOCKER_HAVE=1 "$2/scripts/docker-env" make test
  check "$1: exit 2" [ "$status" -eq 2 ]
  check "$1: says why" [ "$(err_lines)" = "$3|" ]
  check "$1: no docker call" [ "$(calls)" -eq 0 ]
}
worktree "$trees/nogitdir" "unused"
printf 'not a gitdir line\n' >"$trees/nogitdir/.git"
refused "T18 no gitdir line" "$trees/nogitdir" \
  "docker-env: $trees/nogitdir/.git is a file with no gitdir line"
worktree "$trees/gone" "$tmp/no-such-git-dir"
refused "T18 missing git dir" "$trees/gone" \
  "docker-env: $trees/gone/.git names $tmp/no-such-git-dir, whose common directory $tmp/no-such-git-dir does not exist"

# T19: a .git file that names something other than a git directory, or a
# directory holding the checkout or HOME, is refused, saying which: a
# hand-edited one must not mount a parent of the repository. Each named
# directory has a HEAD, so only the rule under test can refuse it.
mkdir -p "$trees/up"
: >"$trees/up/HEAD"
worktree "$trees/up/inner" ".."
refused "T19 the checkout's parent" "$trees/up/inner" \
  "docker-env: refusing to mount $trees/up, named by $trees/up/inner/.git: it holds $trees/up/inner"
: >"$home/HEAD"
worktree "$trees/home" "$home"
refused "T19 HOME itself" "$trees/home" \
  "docker-env: refusing to mount $home, named by $trees/home/.git: it holds $home"
saved_home=$home
home=$tmp/h2/home
mkdir -p "$home"
: >"$tmp/h2/HEAD"
worktree "$trees/home-parent" "$tmp/h2"
refused "T19 HOME's parent" "$trees/home-parent" \
  "docker-env: refusing to mount $tmp/h2, named by $trees/home-parent/.git: it holds $home"
home=$saved_home
mkdir -p "$trees/not-git"
worktree "$trees/nohead" "$trees/not-git"
refused "T19 a directory with no HEAD" "$trees/nohead" \
  "docker-env: $trees/nohead/.git names $trees/not-git, whose common directory $trees/not-git is not a git directory"
cwd=$main

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
