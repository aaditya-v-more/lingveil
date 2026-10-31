#!/bin/sh
# Translates the bench sets with one engine/model and records timings.
# usage: bench/run.sh <engine> [local-model-id]   (engine: google | apple | local)
# Then: python3 bench/score.py (accuracy) and python3 bench/rate.py (writes ratings).
set -eu
cd "$(dirname "$0")/.."
ENGINE=$1; MODEL=${2:-}
NAME=${MODEL:-$ENGINE}
BIN=build/Lingveil.app/Contents/MacOS/Lingveil
for pair in "to-en:en" "from-en:hi" "from-en:ja"; do
  set_name=${pair%%:*}; tgt=${pair##*:}
  printf '%s %s→%s: ' "$NAME" "$set_name" "$tgt"
  out=$(LINGVEIL_ENGINE=$ENGINE LINGVEIL_LOCAL_MODEL=$MODEL LINGVEIL_TARGET=$tgt \
    LINGVEIL_DEBUG_TEXTS=bench/$set_name.txt LINGVEIL_DEBUG_TEXTS_OUT=bench/out/$NAME-$tgt.txt "$BIN" | grep -E "^round|^error" | tr '\n' ' ')
  echo "$out"
  # Record the warm pass for bench/rate.py.
  ms=$(echo "$out" | sed -nE 's/.*round 1: ([0-9]+) texts in ([0-9]+) ms.*/\2 \1/p')
  [ -n "$ms" ] && python3 - "$NAME" "$tgt" $ms <<'PY'
import json, sys
name, tgt, ms, n = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
p = "bench/times.json"; t = json.load(open(p, encoding="utf-8"))
t.setdefault(name, {})[tgt] = [ms, n]
json.dump(t, open(p, "w", encoding="utf-8"), indent=2)
PY
done
