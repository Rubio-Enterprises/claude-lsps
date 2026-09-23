#!/usr/bin/env bash
set -euo pipefail

if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
  echo "devcontainer-apple: this launcher requires macOS on Apple silicon (Darwin arm64)" >&2
  exit 1
fi

if ! command -v container >/dev/null 2>&1; then
  echo "devcontainer-apple: the Apple container CLI ('container') is required on PATH" >&2
  exit 1
fi

if ! command -v adevcontainer >/dev/null 2>&1; then
  echo "devcontainer-apple: 'adevcontainer' is required on PATH" >&2
  exit 1
fi

if ! adevcontainer doctor; then
  echo "devcontainer-apple: adevcontainer doctor failed; start the Apple container runtime explicitly (run 'container system start'), then retry" >&2
  exit 1
fi

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
exec adevcontainer up -w "$repo_root" "$@"
