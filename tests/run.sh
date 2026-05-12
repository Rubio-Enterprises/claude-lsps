#!/usr/bin/env bash
# Top-level test runner. See tests/lib/framework.sh for the harness.
set -u

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

rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

export ROOT_DIR TESTS_DIR TMP_DIR

# shellcheck source=lib/framework.sh
source "$TESTS_DIR/lib/framework.sh"

PLUGINS=(ansible-language-server bash-language-server cue-lsp pyright regal-lsp vtsls)
export PLUGINS

for f in "$TESTS_DIR"/cases/*.sh; do
  # shellcheck disable=SC1090
  source "$f"
done

run_all
