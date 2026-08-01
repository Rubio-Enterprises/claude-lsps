#!/usr/bin/env bash
# Repo-local SessionStart extension for claude-lsps.
#
# Install the LSP servers exercised by the live test suite. The template-owned
# SessionStart core handles mise and PATH setup before invoking this extension.
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || exit 0
ROOT="$(cd -- "$SCRIPT_DIR/../.." 2>/dev/null && pwd)" || exit 0
cd "$ROOT" || exit 0

log() {
  printf 'claude-lsps: %s\n' "$*" >&2
}

add_path() {
  [ -n "${CLAUDE_ENV_FILE:-}" ] || return 0
  local dir="$1"
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  case ":${PATH:-}:" in
  *":${dir}:"*) return 0 ;;
  esac
  # Literal $PATH is intentional: it expands when the env file is sourced.
  # shellcheck disable=SC2016
  printf 'export PATH="%s:$PATH"\n' "$dir" >>"$CLAUDE_ENV_FILE" || true
}

binaries=(
  pyright-langserver
  bash-language-server
  vtsls
  cue
  regal
)

installers=(
  pyright/hooks/check-pyright.sh
  bash-language-server/hooks/check-bash-language-server.sh
  vtsls/hooks/check-vtsls.sh
  cue-lsp/hooks/check-cue.sh
  regal-lsp/hooks/check-regal.sh
)

all_present=1
for binary in "${binaries[@]}"; do
  command -v "$binary" >/dev/null 2>&1 || {
    all_present=0
    break
  }
done
[ "$all_present" -eq 1 ] && exit 0

log "installing missing LSP server(s) for the live test suite..."
for installer in "${installers[@]}"; do
  [ -f "$installer" ] || continue
  bash "$installer" >&2 || log "${installer} failed (continuing)"
done

if [ -n "${HOME:-}" ]; then
  add_path "$HOME/.local/bin"
fi

npm_root="$(npm prefix -g 2>/dev/null || true)"
[ -n "$npm_root" ] && add_path "${npm_root}/bin"

exit 0
