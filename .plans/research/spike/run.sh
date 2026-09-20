#!/bin/sh
# usage: run.sh NAME.sps [timeout-seconds]  -- runs the program twice in fresh
# processes under gtimeout, saving out/NAME.runN.txt with the exit code appended.
# Output is capped at 64 KiB per run (a runaway loop flooded 64 MB once).
S=/private/tmp/claude-501/-Users-yuzu-github-chez-http-server/2440228f-3288-4faf-9838-18f1bc1cd3d2/scratchpad/spike
export CHEZSCHEMELIBDIRS=/Users/yuzu/github/chez-libuv/src:/Users/yuzu/github/chez-libuv/build/scheme-libs:$S
T=${2:-60}
for i in 1 2; do
  out=$S/out/${1%.sps}.run$i.txt
  gtimeout $T chez --program $S/$1 > $out.raw 2>&1
  rc=$?
  if [ $(wc -c < $out.raw) -gt 65536 ]; then
    head -c 65536 $out.raw > $out; echo "" >> $out; echo "[output truncated at 64 KiB; raw size $(wc -c < $out.raw) bytes]" >> $out
  else cp $out.raw $out; fi
  rm -f $out.raw
  echo "exit=$rc" >> $out
  echo "== $1 run $i (gtimeout $T) =="; cat $out
done
