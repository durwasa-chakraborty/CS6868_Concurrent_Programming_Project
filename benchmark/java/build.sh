#!/usr/bin/env bash
# Compile the Java benchmark classes into benchmark/java/classes.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/src"
OUT="$HERE/classes"

mkdir -p "$OUT"
# Collect every .java under src/ and feed it to javac in one go.
find "$SRC" -name '*.java' -print0 | xargs -0 javac -d "$OUT" -source 17 -target 17

echo "built -> $OUT"
