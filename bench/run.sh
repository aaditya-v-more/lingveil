#!/bin/sh
# Translates the bench sets with one engine/model and records timings.
# usage: bench/run.sh <engine> [local-model-id]   (engine: google | apple | local)
set -eu
cd "$(dirname "$0")/.."
ENGINE=$1; MODEL=${2:-}
NAME=${MODEL:-$ENGINE}
BIN=build/Lingveil.app/Contents/MacOS/Lingveil
for pair in "to-en:en" "from-en:hi" "from-en:ja"; do
  set_name=${pair%%:*}; tgt=${pair##*:}
  printf '%s %s→%s: ' "$NAME" "$set_name" "$tgt"
  LINGVEIL_ENGINE=$ENGINE LINGVEIL_LOCAL_MODEL=$MODEL LINGVEIL_TARGET=$tgt \
    LINGVEIL_DEBUG_TEXTS=bench/$set_name.txt LINGVEIL_DEBUG_TEXTS_OUT=bench/out/$NAME-$tgt.txt "$BIN" | tr '\n' ' '
  echo
done
