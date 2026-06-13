#!/usr/bin/env bash
# scripts/cloud-setup.sh — version-controlled reference copy of the Claude Code
# on the web "Setup script" for claude-lsps's cloud environment.
#
# This file holds the real setup logic — do NOT paste this whole file into the
# cloud "Setup script" (web UI) field. Paste ONLY the thin wrapper between the
# two "8<" COPY markers below: it stays version-controlled and PR-reviewed here
# instead of pasted-and-forgotten, and it LOCATES this script at runtime rather
# than assuming a path (the cloud Setup script's working directory is NOT the
# repo root, so a bare `bash scripts/cloud-setup.sh` fails with exit 127). The
# block below is an inert heredoc — read and discarded by `:`, never executed —
# so the wrapper is raw, ready-to-paste text: NO comment-stripping needed, just
# copy everything between the two marker lines.
: <<'CLOUD_SETUP_WEB_WRAPPER'

# ===== 8< ===== COPY FROM THE NEXT LINE INTO THE WEB "Setup script" FIELD =====
#!/usr/bin/env bash
# Repo-agnostic: this EXACT block works in every repo's cloud environment —
# nothing below is project-specific, so one shared block fits the whole fleet.
# Bump CACHE_EPOCH (e.g. 1 -> 2) and re-save this field to force an env-cache rebuild.
CACHE_EPOCH=1
export CACHE_EPOCH
for d in "${CLAUDE_PROJECT_DIR:-}" "$PWD"; do
  for sub in scripts Scripts; do
    [ -n "$d" ] && [ -f "$d/$sub/cloud-setup.sh" ] &&
      { cd "$d" && exec bash "$sub/cloud-setup.sh"; }
  done
done
s="$(find /home /root /workspace -maxdepth 5 -iname cloud-setup.sh -ipath '*/scripts/*' 2>/dev/null | head -n1)"
[ -n "$s" ] && { cd "$(dirname "$s")/.." && exec bash "$s"; }
echo "cloud-setup.sh not found on this branch; SessionStart hook will bootstrap" >&2
# ===== 8< ===== COPY UP TO THE PREVIOUS LINE =====

CLOUD_SETUP_WEB_WRAPPER
#
# Forcing a rebuild on demand: the snapshot is rebuilt ONLY when the UI
# Setup-script TEXT changes, when the environment's ALLOWED NETWORK HOSTS
# change, or at the ~7-day expiry — it CANNOT see edits to THIS file, and
# env-var changes do NOT count. So after editing this script, bump CACHE_EPOCH
# in the UI wrapper and re-save. The SessionStart hook
# (scripts/claude-session-start.sh) re-hashes the checked-out script against a
# fingerprint baked into the snapshot (written at the bottom of this file to
# ${XDG_CACHE_HOME:-$HOME/.cache}/$(basename "$repo_root")/cloud-setup.built —
# see the drift-fingerprint note there) and surfaces a NOTE when a bump is due.
# The hook reads that SAME runtime-basename path, so the two agree byte-for-byte.
# https://code.claude.com/docs/en/claude-code-on-the-web#environment-caching
#
# Execution model (cloud only): runs as root on Ubuntu, BEFORE Claude Code
# launches, and ONLY when no cached environment snapshot exists. Its filesystem
# output is snapshotted and reused, so everything here is paid once per cache
# build (~7 days), not per session. Keep total runtime under ~5 minutes so the
# cache can build; independent work runs in parallel below.
#
# Division of labour:
#   * Only root/apt installs, the private-marketplace git credential helper,
#     and snapshot-cacheable warming live here.
#   * Everything portable (the pinned mise toolchain) lives in
#     scripts/claude-session-start.sh so it runs in BOTH local and cloud
#     sessions. This script just calls that hook so the toolchain lands in the
#     snapshot; the per-session SessionStart hook then fast-paths to a no-op.
#
# PRIVATE marketplace auth (REQUIRED only for PRIVATE org plugin bundles):
#   Public org marketplaces (rubio-standards@rubio, claude-lsps) install in
#   cloud with NO token. PRIVATE in-org bundle marketplaces declared in
#   .claude/settings.json need a GH_PAT — a fine-grained PAT (Rubio-Enterprises,
#   Contents:Read on the private marketplace repos) set in each environment's
#   "Environment variables" UI field. ONE shared, narrowly-scoped, read-only
#   token reused across ALL cloud environments is sufficient: "per environment"
#   means the GH_PAT var must be PRESENT in each environment's settings, NOT that
#   each environment needs a DISTINCT token. The per-marketplace-repo credential
#   helper registered below (after the apt step, once jq is available) reads it
#   at CLONE time and is scoped so the read-only token only ever authenticates
#   the marketplace clones, never the working repo. The cloud GitHub token is
#   injected at SESSION start, NOT at setup time, so the helper must be a RUNTIME
#   helper (it cannot embed a token that is not present yet). GH_PAT is a
#   distinct name so it takes precedence over the auto-injected,
#   working-repo-scoped GH_TOKEN for those marketplace repos.
set -uo pipefail

# Operate from the repo root regardless of the caller's cwd (the UI Setup script
# does NOT start at the repo root). Resolve from this file's own location.
src="${BASH_SOURCE[0]:-$0}"
unset CDPATH
repo_root="$(cd -- "$(dirname -- "$src")/.." 2>/dev/null && pwd)"
if [ -z "$repo_root" ] || ! cd -- "$repo_root"; then
  echo "cloud-setup: cannot resolve repo root from $src; skipping" >&2
  exit 0
fi

echo "cloud-setup: building claude-lsps environment cache (epoch ${CACHE_EPOCH:-unset})" >&2

# --- Marketplace SSH->HTTPS rewrite (early; helper registered after apt) -----
# Rewrite git@github.com: SSH-form marketplace sources to HTTPS so the runtime
# credential helper (registered AFTER the apt step below, once `jq` is installed
# to parse the carrier and scope the helper per-repo) can authenticate them.
# Idempotent; non-fatal.
git config --global url."https://github.com/".insteadOf "git@github.com:" || true

# apt (root-only — cannot live in the portable hook) runs in parallel with the
# toolchain bootstrap to stay within the cache-build time budget.
#   gh — not pre-installed in the cloud image; some workflows need the CLI
#        beyond the built-in GitHub tools.
#   jq — parse the committed .claude/settings.json so the marketplace credential
#        helper can be scoped per-repo (registered after this install finishes).
# Non-fatal: a Setup script that exits non-zero blocks the session from
# starting, so a transient apt blip must not abort the whole cache build.
(
  export DEBIAN_FRONTEND=noninteractive
  apt-get update && apt-get install -y --no-install-recommends gh jq
) &
apt_pid=$!

# Same bootstrap the SessionStart hook runs. Installing it here bakes the pinned
# mise toolchain into the snapshot. CLAUDE_CODE_REMOTE=true forces the hook's
# cloud branch (the var isn't reliably exported this early). GH_TOKEN ->
# GITHUB_TOKEN lets mise's aqua/github backends fetch release metadata without
# the unauthenticated GitHub rate limit (the hook also bridges this internally;
# belt-and-suspenders). Guarded so a greenfield render with no hook yet no-ops.
if [ -f scripts/claude-session-start.sh ]; then
  CLAUDE_CODE_REMOTE=true GITHUB_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}" \
    bash scripts/claude-session-start.sh || true
fi

wait "$apt_pid" || echo "cloud-setup: gh/jq install failed (non-fatal; built-in GitHub tools still work; credential helper falls back to global)" >&2

# --- Private-marketplace git credential helper (RUNTIME, repo-scoped) --------
# Register a runtime credential helper for the PRIVATE in-org marketplace repos
# ONLY, so Claude Code's native marketplace clone (at SESSION start — the token
# is injected then, not now) authenticates with the read-only GH_PAT while the
# WORKING repo keeps using its own session-injected token. The repos are derived
# from the committed carrier's extraKnownMarketplaces (github sources); BOTH the
# bare and ".git" clone-URL forms are registered because git credential
# URL-matching is exact, not suffix-tolerant. Scoping is per-REPO — never a
# global helper, never a github.com/<org> prefix (an org prefix over-matches
# EVERY repo in the org, including the working repo, and would hand it the
# read-only token, breaking working-repo writes). Net effect: ONE shared,
# narrowly-scoped, read-only GH_PAT can never interfere with working-repo auth.
# Token precedence GH_PAT -> GH_TOKEN -> GITHUB_TOKEN, resolved at CLONE time.
# Do NOT use `gh auth setup-git` (errors "not logged into any GitHub hosts").
# Degrades to a single global helper if jq is unavailable or the carrier
# declares no github marketplaces, so a private clone never silently loses auth.
# Idempotent (git config --global overwrites); non-fatal.
# shellcheck disable=SC2016  # ${GH_PAT:-...} must stay literal and expand at clone time, not now
__mkt_helper='!f(){ echo username=x-access-token; echo "password=${GH_PAT:-${GH_TOKEN:-${GITHUB_TOKEN:-}}}"; };f'
__mkt_repos=""
if command -v jq >/dev/null 2>&1 && [ -f .claude/settings.json ]; then
  __mkt_repos="$(jq -r '
    (.extraKnownMarketplaces // {})
    | to_entries[]
    | .value.source
    | select(type == "object" and .source == "github" and (.repo | type == "string"))
    | .repo
  ' .claude/settings.json 2>/dev/null | sort -u)"
fi
if [ -n "$__mkt_repos" ]; then
  printf '%s\n' "$__mkt_repos" | while IFS= read -r __repo; do
    [ -z "$__repo" ] && continue
    git config --global "credential.https://github.com/${__repo}.helper" "$__mkt_helper" || true
    git config --global "credential.https://github.com/${__repo}.git.helper" "$__mkt_helper" || true
  done
  echo "cloud-setup: scoped marketplace credential helper to: $(printf '%s' "$__mkt_repos" | tr '\n' ' ')" >&2
else
  # Degraded path: no jq or no github marketplaces in the carrier. Use a single
  # global helper so a private clone is never left unauthenticated. A read-only
  # GH_PAT here could shadow the working-repo token for git WRITES — acceptable
  # only as the fallback when per-repo scoping is impossible.
  git config --global credential.helper "$__mkt_helper" || true
  echo "cloud-setup: global marketplace credential helper (jq/carrier unavailable; unscoped fallback)" >&2
fi

# --- Cache warming (caching-only; safe to delete) ---------------------------
# Only the setup script's filesystem output is snapshotted — a session's own
# build/test never enters the cache — so warm the archetype's dependency and
# build caches here. All steps are non-fatal: a hiccup must not block the cache
# build (the SessionStart hook / test runner installs on demand if anything
# ends up missing).

# --- Drift fingerprint for the SessionStart hook ----------------------------
# Snapshot-persisted sha256 of THIS script + the epoch it built under. The
# per-session hook re-hashes the checked-out script and warns when they differ
# (cloud-setup.sh edited but CACHE_EPOCH not bumped -> stale snapshot). The
# platform can't detect this: the cache keys off the UI wrapper text. Non-fatal.
#
# CACHE-KEY CONVENTION (coherence-critical — do NOT change to {{ project_name }}):
# the marker is keyed on the RUNTIME checked-out directory name,
# $(basename "$repo_root"), NOT the copier `project_name` answer. The rendered
# SessionStart hook (scripts/claude-session-start.sh, from S-1) derives its
# drift-NOTE path the SAME way — $(basename "$repo_root") — so the path this
# script WRITES and the path the hook READS are byte-identical regardless of
# whether project_name happens to match the checkout-dir name. Keying either
# side on {{ project_name }} would silently break the NOTE whenever a consumer
# clones into a directory whose name differs from project_name. (The standards
# repo's own hand-fixed hook, S-11, hardcodes the `standards` segment instead;
# that is an accepted divergence only because the standards repo basename IS
# `standards` and it has no copier project_name.)
marker_dir="${XDG_CACHE_HOME:-$HOME/.cache}/$(basename "$repo_root")"
if mkdir -p "$marker_dir" 2>/dev/null; then
  {
    printf 'epoch=%s\n' "${CACHE_EPOCH:-unset}"
    printf 'sha256=%s\n' "$(sha256sum scripts/cloud-setup.sh 2>/dev/null | awk '{print $1}')"
  } >"$marker_dir/cloud-setup.built" 2>/dev/null || true
fi

echo "cloud-setup: complete." >&2
exit 0
