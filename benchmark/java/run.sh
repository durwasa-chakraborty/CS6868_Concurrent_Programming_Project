#!/usr/bin/env bash
# Run the Java benchmark driver.  All arguments are forwarded to
# BenchRunner (e.g. --out, --threads, --repeats).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
java -cp "$HERE/classes" com.cs6868.bench.BenchRunner "$@"
