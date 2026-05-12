# Static analysis on installer scripts: bash syntax and shellcheck.

tc_installer_bash_syntax() {
  local rc=0 p f
  for p in "${PLUGINS[@]}"; do
    for f in "$ROOT_DIR/$p/hooks/"check-*.sh; do
      [[ -f "$f" ]] || continue
      if ! bash -n "$f" 2>&1; then
        echo "bash -n failed: $f"
        rc=1
      fi
    done
  done
  return $rc
}

tc_installer_shellcheck() {
  local rc=0 p f
  for p in "${PLUGINS[@]}"; do
    for f in "$ROOT_DIR/$p/hooks/"check-*.sh; do
      [[ -f "$f" ]] || continue
      if ! shellcheck "$f"; then
        echo "shellcheck failed: $f"
        rc=1
      fi
    done
  done
  return $rc
}

register_test "installer/bash-syntax" tc_installer_bash_syntax
register_test "installer/shellcheck" tc_installer_shellcheck
