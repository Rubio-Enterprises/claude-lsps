# Helpers to construct a mocked PATH sandbox for installer-script tests.
# Sourced by 04-installer-behavior.sh and 05-installer-concurrency.sh.

# Copy and patch a check-*.sh script so its LOCK_FILE paths live inside the
# sandbox dir (i.e. alongside the patched script itself). Scoping to the
# sandbox isolates tests from each other: two scenarios for the same plugin
# don't share lockfile state. Concurrency tests run both invocations against
# the same sandbox so they intentionally share the lockfile.
# Usage: patch_installer <plugin> <out-path>
patch_installer() {
  local plugin="$1" out="$2"
  local src
  src=$(ls "$ROOT_DIR/$plugin/hooks/"check-*.sh | head -n1)
  local sbx_dir
  sbx_dir=$(dirname "$out")
  # /tmp/claude-lsp-<kind>.lock => $sbx/lock-<kind>.lock
  local prefix="${sbx_dir}/lock-"
  sed "s|/tmp/claude-lsp-|${prefix}|g" "$src" > "$out"
  chmod +x "$out"
}

# Create a fake install command that:
#   - logs its call to $log
#   - on completion creates a fake binary at $bin_dir/$target (if $target non-empty)
# Usage: make_install_mock <bin_dir> <mock_name> <log> <target_binary>
make_install_mock() {
  local bin_dir="$1" name="$2" log="$3" target="${4:-}"
  cat >"$bin_dir/$name" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "$name" "\$*" >> "$log"
EOF
  if [[ -n "$target" ]]; then
    cat >>"$bin_dir/$name" <<EOF
mkdir -p "$bin_dir"
tmpf=\$(mktemp "$bin_dir/.tmp.XXXXXX")
printf '#!/usr/bin/env bash\nexit 0\n' > "\$tmpf"
chmod +x "\$tmpf"
mv "\$tmpf" "$bin_dir/$target"
EOF
  fi
  chmod +x "$bin_dir/$name"
}

# Fake curl that:
#   - logs the full argv
#   - in "-o <path>" mode, writes a stub executable to <path>
#   - otherwise, writes 1 byte to stdout (so pipes don't appear empty)
make_curl_mock() {
  local bin_dir="$1" log="$2"
  cat >"$bin_dir/curl" <<EOF
#!/usr/bin/env bash
printf 'curl %s\n' "\$*" >> "$log"
out=""
args=( "\$@" )
i=0
while (( i < \${#args[@]} )); do
  case "\${args[\$i]}" in
    -o) out="\${args[\$((i+1))]}"; i=\$((i+2)) ;;
    *) i=\$((i+1)) ;;
  esac
done
if [[ -n "\$out" ]]; then
  mkdir -p "\$(dirname "\$out")"
  printf '#!/usr/bin/env bash\nexit 0\n' > "\$out"
  chmod +x "\$out"
else
  printf 'X'
fi
EOF
  chmod +x "$bin_dir/curl"
}

# Fake tar that logs and, when given "-C <dir>", produces a "cue" stub there.
# Reads and discards stdin so the upstream curl doesn't SIGPIPE.
make_tar_mock() {
  local bin_dir="$1" log="$2"
  cat >"$bin_dir/tar" <<EOF
#!/usr/bin/env bash
printf 'tar %s\n' "\$*" >> "$log"
cdir="."
args=( "\$@" )
i=0
while (( i < \${#args[@]} )); do
  case "\${args[\$i]}" in
    -C) cdir="\${args[\$((i+1))]}"; i=\$((i+2)) ;;
    *) i=\$((i+1)) ;;
  esac
done
cat >/dev/null
mkdir -p "\$cdir"
printf '#!/usr/bin/env bash\nexit 0\n' > "\$cdir/cue"
chmod +x "\$cdir/cue"
EOF
  chmod +x "$bin_dir/tar"
}

# Symlink the system tools the installer scripts genuinely need (bash, flock,
# mkdir, etc.) into the sandbox bin so we can use a fully-controlled PATH that
# does NOT include /usr/bin or /bin. This prevents real brew/npm/curl/tar from
# being discovered when an installer script calls `command -v` against them,
# which would turn the "all install methods absent" test into a real install.
_provision_real_tools() {
  local bin_dir="$1"
  local t real
  for t in bash flock mkdir rmdir sleep uname tr mktemp mv chmod rm cat grep sed awk; do
    [[ -e "$bin_dir/$t" ]] && continue
    real=$(command -v "$t" 2>/dev/null) || continue
    ln -s "$real" "$bin_dir/$t"
  done
}

# Build a fresh sandbox directory.
# Echoes the sandbox path on stdout.
new_sandbox() {
  local tag="$1"
  local dir="$TMP_DIR/sandbox/$tag"
  rm -rf "$dir"
  mkdir -p "$dir/bin" "$dir/home/.local/bin" "$dir/tmp"
  _provision_real_tools "$dir/bin"
  echo "$dir"
}

# Replace the symlinked real `uname` with a mock that reports a fixed OS/arch.
# Used to exercise OS-conditional code paths (Darwin vs Linux) deterministically.
make_uname_mock() {
  local bin_dir="$1" os="$2" arch="${3:-x86_64}"
  rm -f "$bin_dir/uname"
  cat >"$bin_dir/uname" <<EOF
#!/usr/bin/env bash
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -s) printf '%s\n' "$os" ;;
    -m) printf '%s\n' "$arch" ;;
    -a) printf '%s %s\n' "$os" "$arch" ;;
    *)  printf '%s\n' "$os" ;;
  esac
  shift
done
EOF
  chmod +x "$bin_dir/uname"
}

# Drop flock so the installer scripts' mkdir-lock fallback branch runs.
remove_flock() {
  rm -f "$1/flock"
}

# Failing install mock: logs the call but exits non-zero and does NOT install.
make_install_mock_failing() {
  local bin_dir="$1" name="$2" log="$3"
  cat >"$bin_dir/$name" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "$name" "\$*" >> "$log"
exit 1
EOF
  chmod +x "$bin_dir/$name"
}

# "Lying" install mock: returns success but does not create the binary,
# so the script's post-install command -v check fails.
make_install_mock_silent_failure() {
  local bin_dir="$1" name="$2" log="$3"
  cat >"$bin_dir/$name" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "$name" "\$*" >> "$log"
exit 0
EOF
  chmod +x "$bin_dir/$name"
}
