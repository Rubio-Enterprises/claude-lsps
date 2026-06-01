#!/usr/bin/env bash
# scripts/session-bootstrap.sh — repo-owned bespoke SessionStart bootstrap.
#
# Auto-run by scripts/claude-session-start.sh (the canonical template hook) AFTER
# its mise warmup, via the template's `(8)` session-bootstrap drop-in block. By
# the time this runs, the pinned lint/hook toolchain from .mise.toml (lefthook,
# the shellcheck/shfmt pair, gitleaks, yq, markdownlint-cli2, prettier, yamllint,
# commitlint) is already installed and the mise shims dir is on PATH — so this
# script does NOT re-warm mise. It does only the part the template cannot know
# about: install the LSP servers the live test suite (tests/) exercises.
#
# Output discipline: a SessionStart hook's stdout is injected into Claude's
# context, so this script keeps stdout empty and logs only to stderr. It always
# exits 0 — SessionStart hooks cannot block the session, and a failed install
# should degrade gracefully (live tests skip, surfaced by live/skip-report), not
# abort the session or emit noise.
set -uo pipefail

# Resolve the repo root from THIS script's own location (BASH_SOURCE), not from
# CLAUDE_PROJECT_DIR or the caller's cwd — the multi-repo-safe pattern. This
# script lives at scripts/session-bootstrap.sh, so the repo root is one dir up.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT" || exit 0

# Append a dir to PATH for subsequent Bash commands this session, via the
# SessionStart-provided env file. Guarded so it's a no-op when the env file is
# absent (e.g. a plain local invocation), the dir is missing, or it's already
# on PATH (e.g. the cloud image, where these are present).
add_path() {
  [ -n "${CLAUDE_ENV_FILE:-}" ] || return 0
  local dir="$1"
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  case ":${PATH}:" in
  *":${dir}:"*) return 0 ;;
  esac
  # Literal $PATH is intentional: it expands when the env file is sourced.
  # shellcheck disable=SC2016
  printf 'export PATH="%s:$PATH"\n' "$dir" >>"$CLAUDE_ENV_FILE"
}

# ---------------------------------------------------------------------------
# LSP servers exercised by the live test suite (tests/). The mise-pinned
# lint/hook toolchain is already installed and on PATH by the canonical hook
# (scripts/claude-session-start.sh) before this script runs, so there is no mise
# warmup here — only the LSP servers, which the template cannot know about.
# ---------------------------------------------------------------------------
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
