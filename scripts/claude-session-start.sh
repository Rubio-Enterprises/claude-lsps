#!/usr/bin/env bash
# scripts/claude-session-start.sh — SessionStart hook for Claude Code.
#
# Wired into .claude/settings.json (matcher "startup|resume"), so it runs AFTER
# Claude Code launches, on every session, in BOTH local and Claude Code on the
# web (cloud) environments. Follows the org contract proven by gha-outrunner,
# vibe-kanban, and karakeep: a thin cloud "Setup script" (scripts/cloud-setup.sh)
# warms the env-cache by running this hook's installs once; every later session
# re-runs this hook as a fast, idempotent no-op.
#
#   https://code.claude.com/docs/en/claude-code-on-the-web#setup-scripts-vs-sessionstart-hooks
#   https://code.claude.com/docs/en/hooks#sessionstart
#
# Contract (rubio-standards §6.1 — enforced by check.sh on CONTENT):
#   1. Abort-proof: every network/install/toolchain step is `|| true`, and the
#      script ALWAYS ends in `exit 0`. A SessionStart hook must never abort the
#      session. `set -euo pipefail` is kept for shellcheck/convention parity, so
#      every fallible step below is explicitly guarded.
#   2. Bridge GH_TOKEN -> GITHUB_TOKEN (mise's aqua backend resolves release
#      metadata via api.github.com and 403s on the unauthenticated rate limit).
#   3. Persist PATH via $CLAUDE_ENV_FILE — the only mechanism that exposes tools
#      to a session's later Bash calls (in-process exports do not carry).
#   4. Resolve the repo root from THIS script's location (BASH_SOURCE), NOT from
#      CLAUDE_PROJECT_DIR, which in multi-repo workspaces may point at a parent
#      directory. CLAUDE_PROJECT_DIR is used only as a non-authoritative sanity
#      cross-check (a warning on mismatch).
#   5. Emit a cloud-setup drift NOTE on stdout when scripts/cloud-setup.sh and
#      its snapshot-persisted fingerprint disagree (silent no-op locally).
#   6. Emit ONE concise line on stdout (a SessionStart hook's stdout becomes
#      Claude's context); all install chatter goes to stderr.
#   7. Idempotent: check-if-present before reinstalling.
set -euo pipefail

# Self-bootstrap PATH: hooks run as non-login non-interactive shells, which do
# not source /etc/profile.d. Add mise's install + shims dirs so `mise` resolves
# regardless of how the hook was invoked.
export PATH="${HOME:-/root}/.local/bin:${HOME:-/root}/.local/share/mise/shims:$PATH"

log() { printf '[session-start] %s\n' "$*" >&2; }
warn() { printf '[session-start] WARN: %s\n' "$*" >&2; }

# (4) Resolve the repo root from this script's own location. This is the
# proven-safe pattern: it works whether the hook is invoked by Claude Code or
# sourced from scripts/cloud-setup.sh, and it does NOT trust CLAUDE_PROJECT_DIR,
# which can point at a parent directory in a multi-repo workspace.
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
# CLAUDE_PROJECT_DIR is a non-authoritative cross-check only: warn on a clear
# mismatch but never override the BASH_SOURCE-derived root.
if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ "${CLAUDE_PROJECT_DIR}" != "$repo_root" ]; then
  log "NOTE: CLAUDE_PROJECT_DIR ($CLAUDE_PROJECT_DIR) differs from the script-derived repo root ($repo_root); using the script-derived root."
fi
cd "$repo_root" || exit 0

# repo-specific session startup (runs before the mise warmup so it is
# independent of the warmup no-mise early-exit paths). Self-guarded sub-script.
if [ -x "$repo_root/scripts/install-lsps.sh" ]; then
  "$repo_root/scripts/install-lsps.sh" || true
fi

# Only act inside this repo — a SessionStart hook can fire in unrelated
# checkouts. The mise manifest is the repo marker.
[ -f .mise.toml ] || exit 0

# (2) Aqua-backed installs hit api.github.com and 403 on the anonymous rate
# limit. Reuse GH_TOKEN when GITHUB_TOKEN isn't already set so the cloud env's
# pre-provisioned token works without extra config. Harmless when neither is set.
if [ -z "${GITHUB_TOKEN:-}" ] && [ -n "${GH_TOKEN:-}" ]; then
  export GITHUB_TOKEN="$GH_TOKEN"
fi

# Ensure the mise binary is reachable. Locally we never install onto the
# developer's machine unprompted; in cloud (CLAUDE_CODE_REMOTE=true) we bootstrap
# it best-effort. Absent mise, the hook is a clean no-op (e.g. swift/bare repos
# whose .mise.toml carries only the shared tool floor still benefit, but a
# missing mise must never fail the session).
if ! command -v mise >/dev/null 2>&1; then
  if [ -x "$HOME/.local/bin/mise" ]; then
    export PATH="$HOME/.local/bin:$PATH"
  elif [ "${CLAUDE_CODE_REMOTE:-}" = "true" ]; then
    log "installing mise"
    curl -fsSL https://mise.run | sh >/dev/null 2>&1 || true
    export PATH="$HOME/.local/bin:$PATH"
  fi
fi
if ! command -v mise >/dev/null 2>&1; then
  warn "mise not on PATH; install it (https://mise.jdx.dev) so the pinned toolchain and lefthook git hooks resolve"
  exit 0
fi

# (7) Idempotent toolchain check: install only when something is missing. A warm
# environment costs well under a second.
if ! mise -C "$repo_root" ls --installed --quiet >/dev/null 2>&1 \
  || ! mise -C "$repo_root" which shellcheck >/dev/null 2>&1; then
  mise trust "$repo_root" >/dev/null 2>&1 || true
  log "installing pinned toolchain via mise"
  mise -C "$repo_root" install || warn "mise install reported errors (often api.github.com rate limiting); re-run 'mise install' if git hooks fail"
fi
mise trust "$repo_root" >/dev/null 2>&1 || true

# (3) Persist PATH for the session's later Bash calls. Expose mise's own bin dir
# (so `mise run`/`mise exec`, used by lefthook, work) plus the mise shims dir.
# Only these dirs are added, so the system language toolchains are never shadowed.
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  mise_bin="$(command -v mise 2>/dev/null)"
  if [ -n "$mise_bin" ]; then
    # Literal $PATH is intentional: it expands when the env file is sourced.
    # shellcheck disable=SC2016
    printf 'export PATH="%s:%s:$PATH"\n' \
      "$(dirname -- "$mise_bin")" \
      "${HOME:-/root}/.local/share/mise/shims" >>"$CLAUDE_ENV_FILE" || true
  fi
fi

# (5) Cloud env-cache drift check. scripts/cloud-setup.sh bakes a fingerprint
# (sha256 of itself) into a snapshot-persisted marker. If the checked-out script
# no longer matches, the snapshot is stale — cloud-setup.sh was edited but
# CACHE_EPOCH in the UI wrapper was not bumped to force a rebuild. Surface that
# as the one stdout NOTE so it reaches Claude as actionable context. Local
# sessions have no marker (the setup script is cloud-only), so this no-ops.
#
# CACHE-KEY CONVENTION (coherence-critical — keep in lockstep with
# scripts/cloud-setup.sh): the marker is keyed on the RUNTIME checked-out
# directory name, $(basename "$repo_root"), NOT the copier project_name answer.
# cloud-setup.sh WRITES the fingerprint to this exact same path, so the path
# this hook READS and the path that script WRITES are byte-identical regardless
# of whether project_name matches the checkout-dir name. Keying this side on the
# project_name answer would silently break the NOTE whenever a consumer clones
# into a directory whose name differs from project_name.
drift_note=""
marker="${XDG_CACHE_HOME:-$HOME/.cache}/$(basename "$repo_root")/cloud-setup.built"
if [ -f "$marker" ] && [ -f "$repo_root/scripts/cloud-setup.sh" ]; then
  built_sha="$(sed -n 's/^sha256=//p' "$marker" 2>/dev/null)"
  current_sha="$(sha256sum "$repo_root/scripts/cloud-setup.sh" 2>/dev/null | awk '{print $1}')"
  if [ -n "$built_sha" ] && [ -n "$current_sha" ] && [ "$built_sha" != "$current_sha" ]; then
    drift_note=' NOTE: scripts/cloud-setup.sh changed since this environment cache was built — bump CACHE_EPOCH in the cloud Setup-script wrapper and re-save to rebuild the snapshot.'
  fi
fi

# (6) SessionStart stdout becomes Claude's context — one concise, archetype-aware
# line. The drift NOTE (if any) is appended.
# shellcheck disable=SC2016
printf 'claude-lsps dev toolchain ready (mise): lefthook, shellcheck, shfmt, gitleaks, markdownlint-cli2, prettier, yamllint, yq on PATH.%s\n' "$drift_note"

exit 0
