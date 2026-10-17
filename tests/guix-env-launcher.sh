#!/bin/sh
# Host-side tests for the Guix development container's scripts. Nothing
# here runs Guix:
#
#   - scripts/guix-env: every case sets GUIX_ENV_DRY_RUN=1, under which the
#     launcher prints `cd <dir>` and then the guix command it would exec,
#     one argument per line. Each case runs a copy of the launcher in a fake
#     tree, so that whether this checkout is a worktree changes nothing;
#   - scripts/guix-env-enter: run directly, against a fake profile.
#
# `make check-guix` runs this before entering the container. Checks name
# themselves, and the exit status is non-zero if any failed.
#
# Single-quoted dollar signs here are literal on purpose: they check that
# `$HOME` and the like pass through unexpanded.
# shellcheck disable=SC2016
set -u

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
launcher=$root/scripts/guix-env
enter=$root/scripts/guix-env-enter

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

pass=0
fail=0

ok()    { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad()   { fail=$((fail + 1)); printf 'FAIL %s\n' "$1" >&2; }
check() { name=$1; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
has()   { grep -Fxq -- "$1" "$tmp/out"; }
lacks() { ! grep -Fq -- "$1" "$tmp/out"; }
count() { grep -Fxc -- "$1" "$tmp/out"; }
lines() { sed -n "$1" "$tmp/out" | tr '\n' '|'; }
tail_lines() { tail -n "$1" "$tmp/out" | tr '\n' '|'; }
err_lines() { tr '\n' '|' <"$tmp/err"; }

# The fake HOME has a space and a non-ASCII letter in it, and holds the
# kinds of credential a developer's HOME does. The container must receive
# none of them.
home="$tmp/fake hôme"
mkdir -p "$home/.ssh" "$home/.config/gh"
: >"$home/.ssh/id_ed25519"
: >"$home/.gitconfig"
: >"$home/.git-credentials"

# Fake trees live under a path with a space in it, as a checkout's may.
trees="$tmp/tr ees"

# tree DIR: a copy of the launcher at DIR/scripts/guix-env, so that DIR is
# the root it computes. Nothing else of the repository is needed.
tree() {
  mkdir -p "$1/scripts"
  cp "$launcher" "$1/scripts/guix-env"
}

# A main checkout, whose .git is a directory, and the git directories of
# the worktrees below, each naming the common directory as git does.
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
# Runs from $cwd in a scrubbed environment. stdout -> $tmp/out,
# stderr -> $tmp/err, exit -> $status.
cwd=$main
run() {
  status=999
  ( cd "$cwd" && env -i HOME="$home" PATH="$PATH" GUIX_ENV_DRY_RUN=1 \
      SSH_AUTH_SOCK="$home/ssh-agent.sock" GH_TOKEN=fake-token "$@" ) \
    >"$tmp/out" 2>"$tmp/err"
  status=$?
}

# ---- scripts/guix-env ----

# prefix ROOT: the guix command's options for a checkout at ROOT, up to the
# --share a worktree adds, one argument per line joined by |.
prefix() {
  printf 'guix|time-machine|-C|channels.scm|--|shell|-m|manifest.scm|--container|--network|--emulate-fhs|%s|%s|' \
    "--expose=$1/scripts/guix-env-nsswitch.conf=/etc/nsswitch.conf" \
    '--preserve=^(TERM|COLORTERM|LANG)$'
}

# T1: no arguments means an interactive bash, behind the pinned prefix, in
# a container with the network, FHS paths, the project's nsswitch.conf over
# the host's, and only three variables let in.
run "$main/scripts/guix-env"
check "T1 no-args exits 0" [ "$status" -eq 0 ]
check "T1 no-args runs from the repo root" [ "$(lines 1p)" = "cd $main|" ]
check "T1 pins guix via channels.scm" \
  [ "$(lines 2,8p)" = "guix|time-machine|-C|channels.scm|--|shell|-m|" ]
check "T1 uses manifest.scm" [ "$(lines 9p)" = "manifest.scm|" ]
check "T1 container flag" has --container
check "T1 network flag, once" [ "$(count --network)" -eq 1 ]
check "T1 emulates FHS" has --emulate-fhs
exposes_nsswitch() {
  [ "$(grep -c -- '^--expose' "$tmp/out")" -eq 1 ] \
    && has "--expose=$main/scripts/guix-env-nsswitch.conf=/etc/nsswitch.conf"
}
check "T1 mounts the project's nsswitch.conf, and nothing else" exposes_nsswitch
preserves_three() {
  [ "$(grep -c -- '^--preserve' "$tmp/out")" -eq 1 ] \
    && has '--preserve=^(TERM|COLORTERM|LANG)$'
}
check "T1 preserves only TERM, COLORTERM and LANG" preserves_three
check "T1 enters through guix-env-enter" \
  [ "$(tail_lines 4)" = "--|sh|scripts/guix-env-enter|bash|" ]
check "T1 main checkout: shares nothing more" lacks --share
check "T1 the whole command" \
  [ "$(lines '1,$p')" = "cd $main|$(prefix "$main")--|sh|scripts/guix-env-enter|bash|" ]

# T2: arguments pass through verbatim, spaces and dollars included.
run "$main/scripts/guix-env" make "a b" '$HOME'
check "T2 args pass through verbatim" \
  [ "$(tail_lines 6)" = '--|sh|scripts/guix-env-enter|make|a b|$HOME|' ]

# T3: nothing from HOME, and no agent socket or token, enters the
# container.
for args in "sh scripts/guix-env-selftest" ""; do
  # shellcheck disable=SC2086
  run "$main/scripts/guix-env" $args
  label=${args:-no-args}
  check "T3 [$label] no --share" lacks "--share"
  check "T3 [$label] exposes only the nsswitch.conf" exposes_nsswitch
  check "T3 [$label] nothing from HOME" lacks "$home"
  check "T3 [$label] no agent socket" lacks "SSH_AUTH_SOCK"
  check "T3 [$label] no token" lacks "GH_TOKEN"
done

# T4: refuse to nest.
run GUIX_ENVIRONMENT=/gnu/store/fake-profile "$main/scripts/guix-env" make help
check "T4 nested: exit 2" [ "$status" -eq 2 ]
check "T4 nested: names GUIX_ENVIRONMENT" grep -Fq "/gnu/store/fake-profile" "$tmp/err"
check "T4 nested: prints no command" [ ! -s "$tmp/out" ]

# T5: launched by relative path from a subdirectory, the container still
# gets the repo root.
mkdir -p "$main/sub"
cwd=$main/sub
run ../scripts/guix-env make help
cwd=$main
check "T5 subdirectory: exits 0" [ "$status" -eq 0 ]
check "T5 subdirectory: runs from the repo root" [ "$(lines 1p)" = "cd $main|" ]

# T10: a linked worktree outside the main checkout shares the main
# repository's .git, the common directory, and only that. The flag comes
# before the `--` that ends guix's options.
wt_cmd() {  # ROOT SHARED
  printf 'cd %s|%s--share=%s|--|sh|scripts/guix-env-enter|make|test|' "$1" "$(prefix "$1")" "$2"
}
worktree "$trees/out" "$main/.git/worktrees/out"
cwd=$trees/out
run "$trees/out/scripts/guix-env" make test
check "T10 worktree outside: exit 0" [ "$status" -eq 0 ]
check "T10 worktree outside: the whole command" \
  [ "$(lines '1,$p')" = "$(wt_cmd "$trees/out" "$main/.git")" ]

# T11: one inside the main checkout's tree, as `.claude/worktrees/` puts
# them, still needs the share: the container shares only the worktree.
worktree "$main/.claude/worktrees/in" "$main/.git/worktrees/in"
cwd=$main/.claude/worktrees/in
run "$main/.claude/worktrees/in/scripts/guix-env" make test
check "T11 worktree inside main: the whole command" \
  [ "$(lines '1,$p')" = "$(wt_cmd "$main/.claude/worktrees/in" "$main/.git")" ]

# T12: a relative gitdir (worktree.useRelativePaths) resolves from the
# worktree's root, and an absolute commondir is taken as it is.
worktree "$trees/rel" "../main/.git/worktrees/rel"
cwd=$trees/rel
run "$trees/rel/scripts/guix-env" make test
check "T12 relative gitdir: shares the common directory" \
  [ "$(lines '1,$p')" = "$(wt_cmd "$trees/rel" "$main/.git")" ]
worktree "$trees/abs" "$main/.git/worktrees/abs"
cwd=$trees/abs
run "$trees/abs/scripts/guix-env" make test
check "T12 absolute commondir: shares the common directory" \
  [ "$(lines '1,$p')" = "$(wt_cmd "$trees/abs" "$main/.git")" ]

# T13: a separate git directory (`git init --separate-git-dir`) has no
# commondir: the git directory itself is shared. One inside the tree is
# shared already, and adds nothing.
mkdir -p "$trees/separate-git"
: >"$trees/separate-git/HEAD"
worktree "$trees/sep" "$trees/separate-git"
cwd=$trees/sep
run "$trees/sep/scripts/guix-env" make test
check "T13 separate git dir: shares it" \
  [ "$(lines '1,$p')" = "$(wt_cmd "$trees/sep" "$trees/separate-git")" ]
mkdir -p "$trees/own/.real-git"
: >"$trees/own/.real-git/HEAD"
worktree "$trees/own" ".real-git"
cwd=$trees/own
run "$trees/own/scripts/guix-env" make test
check "T13 git dir inside the tree: shares nothing more" lacks --share
check "T13 git dir inside the tree: exit 0" [ "$status" -eq 0 ]

# T14: a .git file the launcher cannot follow is refused, naming it, and
# nothing runs.
worktree "$trees/nogitdir" "unused"
printf 'not a gitdir line\n' >"$trees/nogitdir/.git"
cwd=$trees/nogitdir
run "$trees/nogitdir/scripts/guix-env" make test
check "T14 no gitdir line: exit 2" [ "$status" -eq 2 ]
check "T14 no gitdir line: says why" \
  [ "$(err_lines)" = "guix-env: $trees/nogitdir/.git is a file with no gitdir line|" ]
check "T14 no gitdir line: prints no command" [ ! -s "$tmp/out" ]
worktree "$trees/gone" "$tmp/no-such-git-dir"
cwd=$trees/gone
run "$trees/gone/scripts/guix-env" make test
check "T14 missing git dir: exit 2" [ "$status" -eq 2 ]
check "T14 missing git dir: says why" \
  [ "$(err_lines)" = "guix-env: $trees/gone/.git names $tmp/no-such-git-dir, whose common directory $tmp/no-such-git-dir does not exist|" ]
check "T14 missing git dir: prints no command" [ ! -s "$tmp/out" ]

# T15: a .git file that names something other than a git directory, or a
# directory holding the checkout or HOME, is refused, saying which, and
# nothing runs: a hand-edited one must not share a parent of the
# repository. Each named directory has a HEAD, so only the rule under test
# can refuse it.
refused_share() {  # LABEL TREE GITDIR EXPECTED-STDERR
  worktree "$2" "$3"
  cwd=$2
  run "$2/scripts/guix-env" make test
  check "T15 $1: exit 2" [ "$status" -eq 2 ]
  check "T15 $1: says why" [ "$(err_lines)" = "$4|" ]
  check "T15 $1: prints no command" [ ! -s "$tmp/out" ]
}
mkdir -p "$trees/up"
: >"$trees/up/HEAD"
refused_share "the checkout's parent" "$trees/up/inner" ".." \
  "guix-env: refusing to share $trees/up, named by $trees/up/inner/.git: it holds $trees/up/inner"
: >"$home/HEAD"
refused_share "HOME itself" "$trees/home" "$home" \
  "guix-env: refusing to share $home, named by $trees/home/.git: it holds $home"
# A HOME whose parent does not hold the trees, or the checkout's own rule
# would refuse it first.
saved_home=$home
home=$tmp/h2/home
mkdir -p "$home"
: >"$tmp/h2/HEAD"
refused_share "HOME's parent" "$trees/home-parent" "$tmp/h2" \
  "guix-env: refusing to share $tmp/h2, named by $trees/home-parent/.git: it holds $home"
home=$saved_home
mkdir -p "$trees/a=b/.git"
: >"$trees/a=b/.git/HEAD"
refused_share "a path with =" "$trees/eq" "$trees/a=b/.git" \
  "guix-env: refusing to share $trees/a=b/.git, named by $trees/eq/.git: guix would split it at the ="
mkdir -p "$trees/not-git"
refused_share "a directory with no HEAD" "$trees/nohead" "$trees/not-git" \
  "guix-env: $trees/nohead/.git names $trees/not-git, whose common directory $trees/not-git is not a git directory"
cwd=$main

# T16: a checkout whose path holds `=` is refused, naming it, and nothing
# runs: guix would split the --expose at the =.
tree "$trees/x=y"
cwd=$trees/x=y
# By relative path: env would take the absolute one, which holds an =, for
# a variable.
run ./scripts/guix-env make test
cwd=$main
check "T16 a checkout path with =: exit 2" [ "$status" -eq 2 ]
check "T16 a checkout path with =: says why" \
  [ "$(err_lines)" = "guix-env: refusing to run from $trees/x=y: guix would split its path at the =|" ]
check "T16 a checkout path with =: prints no command" [ ! -s "$tmp/out" ]

# ---- scripts/guix-env-enter ----

# T6: the in-container entry refuses to run on the host, and runs nothing.
( cd "$tmp" && env -i PATH="$PATH" sh "$enter" sh -c ': >ran' ) \
  >"$tmp/out" 2>"$tmp/err"
status=$?
check "T6 enter on host: exit 2" [ "$status" -eq 2 ]
check "T6 enter on host: says why, and what to use" \
  [ "$(err_lines)" = "guix-env-enter: not inside a Guix environment; use scripts/guix-env|" ]
check "T6 enter on host: runs nothing" [ ! -e "$tmp/ran" ]

# T7: what scripts/guix-env-enter exports, against a fake profile shaped
# like a real one: each entry is a symlink into a fake store.
profile=$tmp/fake-profile
store=$tmp/fake-store
enter_cwd=$tmp/enter-cwd

reset_profile() {
  rm -rf "$profile" "$store" "$enter_cwd"
  mkdir -p "$profile/bin" "$profile/lib/pkgconfig" "$store" "$enter_cwd"
  : >"$store/scheme"
  : >"$store/gcc"
  : >"$store/libuv.pc"
  ln -s "$store/scheme" "$profile/bin/scheme"
  ln -s "$store/gcc" "$profile/bin/gcc"
  ln -s "$store/libuv.pc" "$profile/lib/pkgconfig/libuv.pc"
}

# run_enter: prints CHEZ, CC and LD_LIBRARY_PATH (or "unset") as the
# command sees them, separated by |.
run_enter() {
  status=999
  ( cd "$enter_cwd" && env -i PATH="$PATH" GUIX_ENVIRONMENT="$profile" \
      sh "$enter" sh -c \
      'printf "%s|%s|%s\n" "${CHEZ-}" "${CC-}" "${LD_LIBRARY_PATH-unset}"' ) \
    >"$tmp/out" 2>"$tmp/err"
  status=$?
}
field() { cut -d '|' -f "$1" "$tmp/out"; }

# T7a: a complete profile. Every export names the profile's own entry,
# never the store file it resolves to.
reset_profile
run_enter
check "T7a complete profile: exit 0" [ "$status" -eq 0 ]
check "T7a CHEZ is the profile's scheme" [ "$(field 1)" = "$profile/bin/scheme" ]
check "T7a CC is the profile's gcc" [ "$(field 2)" = "$profile/bin/gcc" ]
check "T7a no LD_LIBRARY_PATH" [ "$(field 3)" = "unset" ]

# T7b-e: a profile missing one entry is refused, naming the entry, and the
# command never runs.
refused() {  # LABEL PATH
  check "$1: exit 2" [ "$status" -eq 2 ]
  check "$1: names $2" grep -Fq "$2" "$tmp/err"
  check "$1: runs nothing" [ ! -s "$tmp/out" ]
}
reset_profile
rm "$profile/lib/pkgconfig/libuv.pc"
run_enter
refused "T7b no libuv.pc" "$profile/lib/pkgconfig/libuv.pc"

reset_profile
rm "$store/libuv.pc"
run_enter
refused "T7c dangling libuv.pc" "$profile/lib/pkgconfig/libuv.pc"

reset_profile
rm "$profile/bin/scheme"
run_enter
refused "T7d no scheme" "$profile/bin/scheme"

reset_profile
rm "$profile/bin/gcc"
run_enter
refused "T7e no gcc" "$profile/bin/gcc"

# T8: the command's arguments pass through verbatim.
reset_profile
( cd "$enter_cwd" && env -i PATH="$PATH" GUIX_ENVIRONMENT="$profile" \
    sh "$enter" printf '%s|' "a b" '$HOME' ) >"$tmp/out" 2>"$tmp/err"
check "T8 enter passes args verbatim" [ "$(cat "$tmp/out")" = 'a b|$HOME|' ]

printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
