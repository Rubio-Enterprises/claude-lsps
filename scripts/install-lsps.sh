#!/usr/bin/env bash
# SessionStart hook: make a fresh session immediately able to run BOTH gates of
# this repo's suite, in cloud and local dev environments —
#   Phase 1: the mise-pinned lint/hook toolchain (lefthook, shellcheck, shfmt,
#            gitleaks, yq, markdownlint, prettier, yamllint, commitlint) that
#            backs `lefthook run pre-commit` and the lint-hooks CI job.
#   Phase 2: the six LSP servers the live test suite (tests/) exercises.
# Both phases reuse the repo's own single-source-of-truth install logic — the
# pinned versions in .mise.toml, and each plugin's idempotent check-*.sh — so
# there is no second copy to drift. Fast by design: when everything is already
# on PATH each phase costs only a handful of `which`/`command -v` checks and
# exits.
#
# Output discipline: a SessionStart hook's stdout is injected into Claude's
# context, so this script keeps stdout empty and logs only to stderr. It always
# exits 0 — SessionStart hooks cannot block the session, and a failed install
# should degrade gracefully (lint still runs via `mise exec`; live tests skip,
# surfaced by live/skip-report), not abort the session or emit noise.
set -uo pipefail

# Resolve the repo root from THIS script's own location (BASH_SOURCE), not from
# CLAUDE_PROJECT_DIR or the caller's cwd — the multi-repo-safe pattern. This
# script lives at scripts/install-lsps.sh, so the repo root is one dir up.
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
# Phase 1 — mise-pinned lint/hook toolchain. .mise.toml is the single source of
# truth for the pins; this just makes them present on PATH so a fresh session
# can run `lefthook run pre-commit --all-files` (and commitlint) without a
# manual `mise install`. Mirrors the org dev-setup practice (gha-outrunner).
# ---------------------------------------------------------------------------
mise_tools=(lefthook shellcheck shfmt gitleaks yq markdownlint-cli2 prettier yamllint commitlint)

# Ensure the `mise` binary is reachable. In cloud we bootstrap it; locally we
# never install onto the developer's machine unprompted.
ensure_mise() {
  command -v mise >/dev/null 2>&1 && return 0
  if [ -x "$HOME/.local/bin/mise" ]; then
    PATH="$HOME/.local/bin:$PATH"
    add_path "$HOME/.local/bin"
    return 0
  fi
  if [ "${CLAUDE_CODE_REMOTE:-}" = "true" ]; then
    curl -fsSL https://mise.run | sh >/dev/null 2>&1 || true
    PATH="$HOME/.local/bin:$PATH"
    add_path "$HOME/.local/bin"
  fi
  command -v mise >/dev/null 2>&1
}

# Print a colon-separated list of each tool's bin dir; non-zero if any tool is
# not yet installed (so the caller knows to run `mise install`).
mise_resolve() {
  local acc="" t p
  for t in "${mise_tools[@]}"; do
    p="$(mise -C "$ROOT" which "$t" 2>/dev/null)" || return 1
    [ -n "$p" ] && [ -x "$p" ] || return 1
    acc="$(dirname -- "$p"):$acc"
  done
  printf '%s' "$acc"
}

if [ -f "$ROOT/.mise.toml" ] && ensure_mise; then
  if ! mise_paths="$(mise_resolve)"; then
    echo "claude-lsps: installing pinned lint/hook toolchain via mise (first run for this environment)..." >&2
    # mise's aqua backend resolves versions via api.github.com; an
    # unauthenticated request rate-limits (403). Reuse the GH_TOKEN already set
    # for the gh CLI so the install isn't throttled.
    if [ -z "${GITHUB_TOKEN:-}" ] && [ -n "${GH_TOKEN:-}" ]; then
      export GITHUB_TOKEN="$GH_TOKEN"
    fi
    mise trust "$ROOT" >/dev/null 2>&1 || true
    mise -C "$ROOT" install >/dev/null 2>&1 ||
      echo "claude-lsps: mise install failed (continuing; lint gate may be unavailable)" >&2
    mise_paths="$(mise_resolve || true)"
  fi
  # Expose mise itself (so `mise exec`/`mise run` used by lefthook resolve) plus
  # each resolved tool dir, for later Bash commands this session.
  add_path "$(dirname -- "$(command -v mise)")"
  if [ -n "${mise_paths:-}" ]; then
    IFS=':' read -r -a _mise_dirs <<<"${mise_paths%:}"
    for _d in "${_mise_dirs[@]}"; do add_path "$_d"; done
  fi
fi

# ---------------------------------------------------------------------------
# Phase 2 — LSP servers exercised by the live test suite (tests/).
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
