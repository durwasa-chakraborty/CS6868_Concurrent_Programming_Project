#!/usr/bin/env bash
# Run the Kotlin benchmark driver.  All arguments are forwarded to
# BenchRunner (e.g. --out, --threads, --repeats).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/lib"
CP="$HERE/classes:$LIB/kotlinx-coroutines-core-jvm-1.9.0.jar:$LIB/kotlin-stdlib-2.3.21.jar:$LIB/annotations-26.0.1.jar"
java -cp "$CP" com.cs6868.bench.BenchRunnerKt "$@"
