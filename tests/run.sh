#!/usr/bin/env bash
# Top-level test runner. See tests/lib/framework.sh for the harness.
#
# -e and pipefail are essential: case files are *sourced* (not exec'd), so a
# syntax error or failed assertion in a register_test body would otherwise let
# the runner march on and report PASS for tests registered before the error.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS_DIR="$ROOT_DIR/tests"
TMP_DIR="$TESTS_DIR/tmp"

REQUIRED_TOOLS=(node bash jq shellcheck)
missing=()
for tool in "${REQUIRED_TOOLS[@]}"; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if (( ${#missing[@]} > 0 )); then
  printf 'missing required tools: %s\n' "${missing[*]}" >&2
  exit 2
fi

# Cheap insurance: refuse to rm anything outside tests/tmp/.
[[ "$TMP_DIR" == */tests/tmp ]] || { echo "refusing to clean unexpected TMP_DIR=$TMP_DIR" >&2; exit 2; }
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# Collect V8 coverage from every Node subprocess the harness launches so the
# final coverage gate can verify the lsp-proxy.js files are well-exercised.
NODE_V8_COVERAGE="$TMP_DIR/cov"
mkdir -p "$NODE_V8_COVERAGE"

export ROOT_DIR TESTS_DIR TMP_DIR NODE_V8_COVERAGE

# shellcheck source=lib/framework.sh
source "$TESTS_DIR/lib/framework.sh"

# Derive PLUGINS from marketplace.json so the suite self-updates when plugins
# are added or renamed. Falls back to a hardcoded list if jq output is empty
# (e.g. malformed manifest), which 01-manifests will catch separately.
mapfile -t PLUGINS < <(jq -r '.plugins[].source | sub("^\\./"; "")' "$ROOT_DIR/.claude-plugin/marketplace.json" | LC_ALL=C sort)
if (( ${#PLUGINS[@]} == 0 )); then
  printf 'could not derive PLUGINS from marketplace.json\n' >&2
  exit 2
fi

for f in "$TESTS_DIR"/cases/*.sh; do
  # shellcheck disable=SC1090
  source "$f"
done

run_all
