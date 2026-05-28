#!/usr/bin/env bash
# SessionStart hook: ensure the six LSP servers the live test suite (tests/)
# exercises are installed, in both cloud and local dev environments. Reuses each
# plugin's own idempotent installer so install logic has a single source of
# truth. Fast by design — if every binary is already on PATH it exits
# immediately, so the common case (warm container / already-set-up laptop) costs
# only a handful of `command -v` checks.
#
# Output discipline: a SessionStart hook's stdout is injected into Claude's
# context, so this script keeps stdout empty and logs only to stderr. It always
# exits 0 — SessionStart hooks cannot block the session, and a failed install
# should degrade to "live tests skip" (surfaced by live/skip-report), not noise.
set -uo pipefail

ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cd "$ROOT" || exit 0

binaries=(
  pyright-langserver
  bash-language-server
  vtsls
  cue
  regal
  ansible-language-server
)
installers=(
  pyright/hooks/check-pyright.sh
  bash-language-server/hooks/check-bash-language-server.sh
  vtsls/hooks/check-vtsls.sh
  ansible-language-server/hooks/check-ansible-language-server.sh
  cue-lsp/hooks/check-cue.sh
  regal-lsp/hooks/check-regal.sh
)

# Append a dir to PATH for subsequent Bash commands this session, via the
# SessionStart-provided env file. Guarded so it's a no-op when the dir is
# missing or already on PATH (e.g. the cloud image, where these are present).
add_path() {
  [ -n "${CLAUDE_ENV_FILE:-}" ] || return 0
  local dir="$1"
  [ -d "$dir" ] || return 0
  case ":${PATH}:" in
  *":${dir}:"*) return 0 ;;
  esac
  printf 'export PATH="%s:$PATH"\n' "$dir" >>"$CLAUDE_ENV_FILE"
}

# Fast path: every server already present → nothing to do.
all_present=1
for b in "${binaries[@]}"; do
  command -v "$b" >/dev/null 2>&1 || {
    all_present=0
    break
  }
done
[ "$all_present" -eq 1 ] && exit 0

echo "claude-lsps: installing missing LSP server(s) for the live test suite..." >&2
for installer in "${installers[@]}"; do
  [ -f "$installer" ] || continue
  bash "$installer" >&2 || echo "claude-lsps: ${installer} failed (continuing)" >&2
done

# cue/regal/pyright land in ~/.local/bin; npm servers in the npm global bin.
# Make both reachable by later Bash commands (no-op where already on PATH).
add_path "$HOME/.local/bin"
npm_root="$(npm prefix -g 2>/dev/null || true)"
[ -n "$npm_root" ] && add_path "${npm_root}/bin"

exit 0
