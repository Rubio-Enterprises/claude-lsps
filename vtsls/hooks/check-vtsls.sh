#!/usr/bin/env bash
# Check/install vtsls for Claude Code LSP plugin

BINARY="vtsls"
FORMULA="vtsls"
NPM_PACKAGE="@vtsls/language-server"

# Every plugin launches its server through the Node proxy (lsp-proxy.js), so a
# usable session needs node on PATH even when the server binary is present.
if ! command -v node &>/dev/null; then
  echo "[$BINARY] node is required to run this plugin's LSP proxy but is not on PATH." >&2
  echo "[$BINARY] Install Node.js (e.g. brew install node), then restart the session." >&2
  exit 1
fi

if command -v "$BINARY" &>/dev/null; then
  exit 0
fi

# Determine install method: Homebrew first, npm fallback
if command -v brew &>/dev/null; then
  INSTALL_METHOD="brew"
  LOCK_FILE="/tmp/claude-lsp-brew.lock"
elif command -v npm &>/dev/null; then
  INSTALL_METHOD="npm"
  LOCK_FILE="/tmp/claude-lsp-npm.lock"
else
  echo "[$BINARY] Neither Homebrew nor npm found. Install one of them first."
  exit 1
fi

LOCK_TIMEOUT=120

do_install() {
  if [ "$INSTALL_METHOD" = "brew" ]; then
    echo "[$BINARY] Installing via Homebrew..."
    if brew install "$FORMULA"; then
      echo "[$BINARY] Installed successfully"
    else
      echo "[$BINARY] brew install failed"
      return 1
    fi
  else
    echo "[$BINARY] Installing via npm..."
    if npm install -g "$NPM_PACKAGE"; then
      echo "[$BINARY] Installed successfully"
    else
      echo "[$BINARY] npm install failed"
      return 1
    fi
  fi
}

# Serialized install (flock with mkdir fallback for macOS)
if command -v flock &>/dev/null; then
  (
    flock --timeout "$LOCK_TIMEOUT" 9 || {
      echo "[$BINARY] Lock timeout"
      exit 1
    }
    command -v "$BINARY" &>/dev/null && exit 0
    do_install
  ) 9>"$LOCK_FILE"
else
  waited=0
  while ! mkdir "$LOCK_FILE.d" 2>/dev/null; do
    if ((waited >= LOCK_TIMEOUT)); then
      echo "[$BINARY] Lock timeout"
      exit 1
    fi
    sleep 2
    ((waited += 2))
  done
  trap 'rmdir "$LOCK_FILE.d" 2>/dev/null' EXIT
  command -v "$BINARY" &>/dev/null || do_install
fi

if ! command -v "$BINARY" &>/dev/null; then
  echo "[$BINARY] Not in PATH after install. Install manually: brew install $FORMULA"
  exit 1
fi
