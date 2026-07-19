#!/usr/bin/env bash
# scripts/common/session-start-claude.sh — TEMPLATE-OWNED core of the
# SessionStart hook for Claude Code.
#
# OWNERSHIP (shim/common/repo-local layout): this file is rendered by the
# rubio-standards template on every `copier update` — do NOT edit it in a
# consumer repo (edits are template drift). The execution chain is:
#   .claude/settings.json hook (matcher "startup|resume") →
#   scripts/session-start-claude-shim.sh (frozen consumer entry) →
#   THIS file (all logic) →
#   scripts/repo-local/session-start-claude.sh (optional, repo-owned startup).
#
# It runs AFTER Claude Code launches, on every session, in BOTH local and
# Claude Code on the web (cloud) environments. Follows the org contract proven
# by gha-outrunner, vibe-kanban, and karakeep: a thin cloud "Setup script"
# (scripts/common/cloud-setup.sh, entered via scripts/cloud-setup-shim.sh)
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
#   5. Emit a cloud-setup drift NOTE on stdout when the cloud-setup pair
#      (scripts/cloud-setup-shim.sh + scripts/common/cloud-setup.sh) and its
#      snapshot-persisted fingerprint disagree (silent no-op locally), and
#      a cloud plugin pre-seed health NOTE (5b) when a carrier-declared
#      marketplace or an enabled plugin's cache copy is missing from the
#      snapshot (silent locally and during the snapshot build itself).
#   6. Emit ONE concise line on stdout (a SessionStart hook's stdout becomes
#      Claude's context); all install chatter goes to stderr.
#   7. Idempotent: check-if-present before reinstalling.
#   8. Optional repo-local startup: after the warmup, run the repo-owned
#      scripts/repo-local/session-start-claude.sh (if present) for startup this
#      template cannot know about — extra toolchains, workspace installs, a dev
#      daemon, env defaults. Committed, repo-owned, NEVER rendered by the
#      template; abort-proof so it can never fail the session. Absent the file
#      this core is unchanged, so every rendered core is the same pure
#      template render.
set -euo pipefail

# Self-bootstrap PATH: hooks run as non-login non-interactive shells, which do
# not source /etc/profile.d. Add mise's install + shims dirs so `mise` resolves
# regardless of how the hook was invoked.
export PATH="${HOME:-/root}/.local/bin:${HOME:-/root}/.local/share/mise/shims:$PATH"

log() { printf '[session-start] %s\n' "$*" >&2; }
warn() { printf '[session-start] WARN: %s\n' "$*" >&2; }

# (4) Resolve the repo root from this script's own location — TWO levels up:
# this core lives at scripts/common/. This is the proven-safe pattern: it works
# whether the core is entered via the shim, invoked directly, or run from
# scripts/common/cloud-setup.sh, and it does NOT trust CLAUDE_PROJECT_DIR,
# which can point at a parent directory in a multi-repo workspace.
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/../.." && pwd)"
# CLAUDE_PROJECT_DIR is a non-authoritative cross-check only: warn on a clear
# mismatch but never override the BASH_SOURCE-derived root.
if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ "${CLAUDE_PROJECT_DIR}" != "$repo_root" ]; then
  log "NOTE: CLAUDE_PROJECT_DIR ($CLAUDE_PROJECT_DIR) differs from the script-derived repo root ($repo_root); using the script-derived root."
fi
cd "$repo_root" || exit 0

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
if ! mise -C "$repo_root" ls --installed --quiet >/dev/null 2>&1 ||
  ! mise -C "$repo_root" which shellcheck >/dev/null 2>&1; then
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

# (8) Optional repo-local startup (scripts/repo-local/session-start-claude.sh).
# The template owns the mise warmup + PATH above and the cloud drift NOTE
# below; a repo drops in startup this template cannot know about (an extra
# language toolchain, a workspace install, a dev daemon, env-var defaults) as
# scripts/repo-local/session-start-claude.sh — REPO-OWNED, committed (cloud
# only runs committed files), NEVER rendered by the template. It runs HERE —
# after the pinned toolchain is installed and reachable (the mise shims dir is
# on PATH from the top of this script, so the child inherits the toolchain) and
# abort-proof (`|| true`) so a hiccup can never fail the session. Absent the
# file this is a zero-cost no-op, so a repo with no bespoke startup renders the
# identical core. The child runs with: cwd = repo root; the pinned toolchain on
# PATH; $CLAUDE_ENV_FILE available to persist its own env/PATH; $GITHUB_TOKEN
# bridged; $CLAUDE_CODE_REMOTE set in cloud. Contract: keep stdout clean (this
# hook's stdout is Claude's context — at most one actionable NOTE; chatter to
# stderr) and end in `exit 0`.
if [ -f "$repo_root/scripts/repo-local/session-start-claude.sh" ]; then
  bash "$repo_root/scripts/repo-local/session-start-claude.sh" || true
fi

# (5) Cloud env-cache drift check. scripts/common/cloud-setup.sh bakes a
# fingerprint (sha256 of the shim + core pair, concatenated) into a
# snapshot-persisted marker. If the checked-out pair no longer matches, the
# snapshot is stale — the cloud-setup core changed (usually via a copier-sync
# PR) but the snapshot predates it. Surface that as the one stdout NOTE so it
# reaches Claude as actionable context. Local sessions have no marker (the
# setup script is cloud-only), so this no-ops.
#
# CACHE-KEY CONVENTION (coherence-critical — keep in lockstep with
# scripts/common/cloud-setup.sh): the marker is keyed on the RUNTIME
# checked-out directory name, $(basename "$repo_root"), NOT the copier
# project_name answer. The cloud-setup core WRITES the fingerprint to this
# exact same path, so the path this hook READS and the path that script WRITES
# are byte-identical regardless of whether project_name matches the
# checkout-dir name. Keying this side on the project_name answer would
# silently break the NOTE whenever a consumer clones into a directory whose
# name differs from project_name. The HASH convention must also stay in
# lockstep: cat shim + core | sha256sum, same file order.
drift_note=""
marker="${XDG_CACHE_HOME:-$HOME/.cache}/$(basename "$repo_root")/cloud-setup.built"
if [ -f "$marker" ] && [ -f "$repo_root/scripts/common/cloud-setup.sh" ]; then
  built_sha="$(sed -n 's/^sha256=//p' "$marker" 2>/dev/null)"
  current_sha="$(cat "$repo_root/scripts/cloud-setup-shim.sh" "$repo_root/scripts/common/cloud-setup.sh" 2>/dev/null | sha256sum | awk '{print $1}')"
  if [ -n "$built_sha" ] && [ -n "$current_sha" ] && [ "$built_sha" != "$current_sha" ]; then
    drift_note=' NOTE: the cloud-setup scripts (scripts/cloud-setup-shim.sh + scripts/common/cloud-setup.sh) changed since this environment cache was built — bump CACHE_EPOCH in the cloud Setup-script wrapper and re-save to rebuild the snapshot.'
  fi
fi

# (5b) Cloud plugin pre-seed health check. scripts/common/cloud-setup.sh
# pre-seeds the carrier's plugin marketplaces into the environment snapshot (its
# "Marketplace pre-seed" section — a workaround while Claude Code on the web
# launches sessions with SKIP_PLUGIN_MARKETPLACE=true, which disables native
# marketplace sync and would otherwise orphan every enabledPlugins entry).
# Every failure mode there is non-fatal by design, so a failed pre-seed
# (missing/expired GH_PAT in the Setup-script wrapper, a network-policy
# block, a snapshot predating the workaround) would otherwise surface only as
# silently missing plugins. A marketplace is healthy only if BOTH its
# on-disk copy and its registry entry exist — tested via the
# .claude-plugin/marketplace.json manifest that resolution actually reads,
# NOT via .git: Claude Code's native handling of claude-plugins-official
# replaces the pre-seeded git clone with a GITLESS directory at session
# start, which is perfectly healthy (observed live). A healthy marketplace
# is still not enough — each enabled plugin must also be installed into the
# plugin cache, or startup resolution drops it with "plugin-cache-miss"
# (observed live: 2 seeded marketplaces, 0 plugins loaded). Cloud-only:
# locally Claude Code
# syncs marketplaces natively and ~/.claude/plugins is none of our business.
# CLOUD_SETUP_BUILD=1 marks the cloud-setup core's own build-time invocation
# of this core, where the pre-seed has not run yet — skip there too. Remove
# this check together with the pre-seed workaround.
plugin_note=""
if [ "${CLAUDE_CODE_REMOTE:-}" = "true" ] && [ -z "${CLOUD_SETUP_BUILD:-}" ] &&
  command -v jq >/dev/null 2>&1 && [ -f "$repo_root/.claude/settings.json" ]; then
  __mkt_missing=""
  __mkt_uncached=""
  __mkt_reg="$HOME/.claude/plugins/known_marketplaces.json"
  __mkt_clones="$HOME/.claude/plugins/marketplaces"
  while IFS= read -r __mkt_name; do
    [ -n "$__mkt_name" ] || continue
    if [ ! -f "$__mkt_clones/$__mkt_name/.claude-plugin/marketplace.json" ] ||
      ! jq -e --arg n "$__mkt_name" 'has($n)' "$__mkt_reg" >/dev/null 2>&1; then
      __mkt_missing="$__mkt_missing $__mkt_name"
    fi
  done <<EOF
$(jq -r '
  (.extraKnownMarketplaces // {})
  | to_entries[]
  | select(.value.source | type == "object" and .source == "github")
  | .key
' "$repo_root/.claude/settings.json" 2>/dev/null)
EOF
  while IFS= read -r __mkt_entry; do
    [ -n "$__mkt_entry" ] || continue
    __mkt="${__mkt_entry##*@}"
    case " $__mkt_missing " in *" $__mkt "*) continue ;; esac
    [ -f "$__mkt_clones/$__mkt/.claude-plugin/marketplace.json" ] || continue
    [ -d "$HOME/.claude/plugins/cache/$__mkt/${__mkt_entry%@*}" ] ||
      __mkt_uncached="$__mkt_uncached $__mkt_entry"
  done <<EOF
$(jq -r '(.enabledPlugins // {}) | to_entries[] | select(.value == true) | .key' "$repo_root/.claude/settings.json" 2>/dev/null)
EOF
  __mkt_issues=""
  [ -n "$__mkt_missing" ] && __mkt_issues="missing marketplaces:$__mkt_missing"
  [ -n "$__mkt_uncached" ] && __mkt_issues="${__mkt_issues:+$__mkt_issues; }uncached plugins:$__mkt_uncached"
  [ -n "$__mkt_issues" ] && plugin_note=" NOTE: cloud plugin pre-seed incomplete — ${__mkt_issues}. The affected plugins/skills will not load. Ensure GH_PAT is exported in the Setup-script WRAPPER (the env-vars field does not reach snapshot builds), then re-save the wrapper to rebuild (see scripts/common/cloud-setup.sh)."
fi

# (5c) Cloud workflow-seeding health check. cloud-setup.sh's "Workflow
# seeding" section copies workflows/<audience>/*.js from any marker-carrying
# plugin in the cache (an empty .claude-plugin/seed-workflows flag file is the
# opt-in) into ~/.claude/workflows/ at snapshot-build time, so the Workflow
# tool resolves them by meta.name in cloud sessions. Every failure mode there
# is non-fatal by design, so an incomplete seed (snapshot predating the
# clause, a plugin cache install that failed, a filename collision that
# skipped a copy) would otherwise surface only as a silently unresolvable
# workflow name. Verify: every payload .js of every marked cached plugin has
# a same-named file in ~/.claude/workflows/. Cloud-only, same gates as 5b.
workflow_note=""
if [ "${CLAUDE_CODE_REMOTE:-}" = "true" ] && [ -z "${CLOUD_SETUP_BUILD:-}" ]; then
  __wf_missing=""
  __wf_cache="$HOME/.claude/plugins/cache"
  if [ -d "$__wf_cache" ]; then
    for __wf_marker in "$__wf_cache"/*/*/.claude-plugin/seed-workflows \
      "$__wf_cache"/*/*/*/.claude-plugin/seed-workflows; do
      [ -f "$__wf_marker" ] || continue
      __wf_root="${__wf_marker%/.claude-plugin/seed-workflows}"
      for __wf_src in "$__wf_root"/workflows/*/*.js; do
        [ -f "$__wf_src" ] || continue
        [ -f "$HOME/.claude/workflows/$(basename "$__wf_src")" ] ||
          __wf_missing="$__wf_missing $(basename "$__wf_src")"
      done
    done
  fi
  [ -n "$__wf_missing" ] && workflow_note=" NOTE: cloud workflow seeding incomplete — missing from ~/.claude/workflows:${__wf_missing}. Those workflow names will not resolve. The snapshot likely predates the seeding clause in scripts/common/cloud-setup.sh — bump CACHE_EPOCH in the Setup-script wrapper and re-save to rebuild."
fi
drift_note="${drift_note}${plugin_note}${workflow_note}"

# (6) SessionStart stdout becomes Claude's context — one concise, stack-aware
# line (first matching stack facet wins; ts-first keeps polyglot repos on the
# message their primary package.json workflow implies). The drift NOTE (if any) is appended.
# shellcheck disable=SC2016
printf 'claude-lsps dev toolchain ready (mise): biome, lefthook, shellcheck, shfmt, gitleaks, prettier, yq on PATH. Use `mise run build/test/lint` (or the package.json scripts).%s\n' "$drift_note"

exit 0
