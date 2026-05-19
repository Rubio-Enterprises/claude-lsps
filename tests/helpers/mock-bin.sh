# shellcheck shell=bash
# Rewrite the installer's hard-coded /tmp/claude-lsp-*.lock paths to live
# inside the sandbox dir, so lockfile state can't leak between scenarios.
# Concurrency tests intentionally share a sandbox so both invocations see the
# same lockfile.
patch_installer() {
  local plugin="$1" out="$2"
  shopt -s nullglob
  local files=("$ROOT_DIR/$plugin/hooks/"check-*.sh)
  shopt -u nullglob
  if ((${#files[@]} == 0)); then
    echo "patch_installer: no check-*.sh in $plugin/hooks/" >&2
    return 1
  fi
  if ((${#files[@]} > 1)); then
    # Don't silently pick `files[0]` from an unsorted glob — fail loudly so a
    # newly added installer script is noticed.
    echo "patch_installer: multiple check-*.sh in $plugin/hooks/: ${files[*]}" >&2
    return 1
  fi
  local prefix
  prefix=$(dirname "$out")/lock-
  sed "s|/tmp/claude-lsp-|${prefix}|g" "${files[0]}" >"$out"
  chmod +x "$out"
  # Sanity check: nothing reaches the real /tmp/claude-lsp- prefix.
  if grep -F '/tmp/claude-lsp-' "$out" >/dev/null; then
    echo "patch_installer: rewrite missed a /tmp/claude-lsp- occurrence in $out" >&2
    return 1
  fi
}

# make_install_mock <bin_dir> <name> <log> [--target=BIN] [--exit=N]
# Omitting --target makes the mock "succeed" without installing anything,
# triggering the installer's post-install missing-binary check.
make_install_mock() {
  local bin_dir="$1" name="$2" log="$3"
  shift 3
  local target="" exit_code=0
  while (($# > 0)); do
    case "$1" in
    --target=*) target="${1#--target=}" ;;
    --exit=*) exit_code="${1#--exit=}" ;;
    *)
      echo "make_install_mock: unknown arg $1" >&2
      return 2
      ;;
    esac
    shift
  done
  cat >"$bin_dir/$name" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "$name" "\$*" >> "$log"
EOF
  if [[ -n "$target" ]]; then
    cat >>"$bin_dir/$name" <<EOF
tmpf=\$(mktemp "$bin_dir/.tmp.XXXXXX")
printf '#!/usr/bin/env bash\nexit 0\n' > "\$tmpf"
chmod +x "\$tmpf"
mv "\$tmpf" "$bin_dir/$target"
EOF
  fi
  printf 'exit %s\n' "$exit_code" >>"$bin_dir/$name"
  chmod +x "$bin_dir/$name"
}

# In `-o PATH` mode the mock writes a stub executable; otherwise it emits one
# byte so a piped consumer (e.g. tar) doesn't see an empty stream.
# Optional --exit=N flag forces the mock to exit non-zero so installer
# error paths (download failed) can be exercised.
make_curl_mock() {
  local bin_dir="$1" log="$2"
  shift 2
  local exit_code=0
  while (($# > 0)); do
    case "$1" in
    --exit=*) exit_code="${1#--exit=}" ;;
    *)
      echo "make_curl_mock: unknown arg $1" >&2
      return 2
      ;;
    esac
    shift
  done
  cat >"$bin_dir/curl" <<EOF
#!/usr/bin/env bash
printf 'curl %s\n' "\$*" >> "$log"
exit_code=$exit_code
out=""
args=( "\$@" )
i=0
while (( i < \${#args[@]} )); do
  case "\${args[\$i]}" in
    -o) out="\${args[\$((i+1))]}"; i=\$((i+2)) ;;
    *) i=\$((i+1)) ;;
  esac
done
if (( exit_code != 0 )); then
  exit \$exit_code
fi
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

# Drains stdin to avoid SIGPIPE on the upstream piped curl.
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

# Sandbox PATH must NOT include /usr/bin: otherwise real brew/npm/curl/tar
# would leak in and turn "all install methods absent" into a real install.
# Symlink only the tools the installer scripts actually need.
_REAL_TOOL_PATHS=()
_resolve_real_tools_once() {
  if ((${#_REAL_TOOL_PATHS[@]} > 0)); then return; fi
  local t real
  for t in bash flock mkdir rmdir sleep uname tr mktemp mv chmod rm cat grep sed awk; do
    real=$(command -v "$t" 2>/dev/null) || continue
    _REAL_TOOL_PATHS+=("$t=$real")
  done
}

_provision_real_tools() {
  local bin_dir="$1"
  _resolve_real_tools_once
  local entry name real
  for entry in "${_REAL_TOOL_PATHS[@]}"; do
    name="${entry%%=*}"
    real="${entry#*=}"
    [[ -e "$bin_dir/$name" ]] && continue
    ln -s "$real" "$bin_dir/$name"
  done
}

new_sandbox() {
  local tag="$1"
  local dir="$TMP_DIR/sandbox/$tag"
  rm -rf "$dir"
  mkdir -p "$dir/bin" "$dir/home/.local/bin" "$dir/tmp"
  _provision_real_tools "$dir/bin"
  echo "$dir"
}

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

remove_flock() {
  rm -f "$1/flock"
}
