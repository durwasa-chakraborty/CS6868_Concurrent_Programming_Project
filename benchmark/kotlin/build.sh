#!/usr/bin/env bash
# Compile the Kotlin benchmark sources into benchmark/kotlin/classes.
# Required jars are vendored under benchmark/kotlin/lib/.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/src"
LIB="$HERE/lib"
OUT="$HERE/classes"

CP="$LIB/kotlinx-coroutines-core-jvm-1.9.0.jar:$LIB/kotlin-stdlib-2.3.21.jar:$LIB/annotations-26.0.1.jar"

mkdir -p "$OUT"
find "$SRC" -name '*.kt' -print0 | xargs -0 kotlinc -cp "$CP" -d "$OUT" -jvm-target 17

echo "built -> $OUT"
