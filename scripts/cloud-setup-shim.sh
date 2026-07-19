#!/usr/bin/env bash
# scripts/cloud-setup-shim.sh — FROZEN consumer entry point for the Claude Code
# on the web Setup script (rubio-standards shim/common/repo-local layout).
#
# The cloud environment's UI Setup-script wrapper locates and execs THIS file.
# It is deliberately logic-free and should never need to change again:
#   - ALL setup logic lives in scripts/common/cloud-setup.sh — TEMPLATE-OWNED,
#     normally rendered, so every change propagates automatically via the
#     weekly copier-sync PR. Do not edit files under scripts/common/ (consumer
#     edits there are template drift).
#   - Repo-specific additions belong in scripts/repo-local/cloud-setup.sh —
#     REPO-OWNED, committed, never rendered by the template; the common core
#     runs it (abort-proof) after its own work.
# This shim is `_skip_if_exists` (consumer-owned once rendered) precisely so
# the entry-point contract stays stable while the core evolves underneath.
#
# Contract: abort-proof — a Setup script that exits non-zero blocks the cloud
# session from starting, so a missing core must degrade, never fail.
set -uo pipefail
src="${BASH_SOURCE[0]:-$0}"
unset CDPATH
repo_root="$(cd -- "$(dirname -- "$src")/.." 2>/dev/null && pwd)"
if [ -n "$repo_root" ] && [ -f "$repo_root/scripts/common/cloud-setup.sh" ]; then
  exec bash "$repo_root/scripts/common/cloud-setup.sh"
fi
echo "cloud-setup-shim: scripts/common/cloud-setup.sh not found on this branch; SessionStart hook will bootstrap" >&2
exit 0
