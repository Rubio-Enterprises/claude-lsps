#!/usr/bin/env bash
# On-demand latency harness for the marketplace LSPs. Prints a median/min table
# of spawn->ready and didOpen->first-diagnostic times (plus pyright's
# change->refresh). This is a MEASUREMENT, not a pass/fail gate — it is
# deliberately separate from tests/run.sh so the suite stays quiet-on-success
# while these numbers stay visible on stdout.
#
#   bash tests/perf.sh            # 3 cold spawns per server (default)
#   PERF_ITERS=5 bash tests/perf.sh
#
# Servers whose binary is not installed are reported as skipped, not failed.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS_DIR="$ROOT_DIR/tests"
TMP_DIR="$TESTS_DIR/tmp-perf"

command -v node >/dev/null 2>&1 || {
  echo "missing required tool: node" >&2
  exit 2
}

# Cheap insurance: refuse to clean anything outside tests/tmp-perf/.
[[ "$TMP_DIR" == */tests/tmp-perf ]] || {
  echo "refusing to clean unexpected TMP_DIR=$TMP_DIR" >&2
  exit 2
}
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

export ROOT_DIR TESTS_DIR TMP_DIR

node "$TESTS_DIR/helpers/perf-suite.js"
