tc_installer_bash_syntax() {
  local rc=0 p f matched=0
  for p in "${PLUGINS[@]}"; do
    shopt -s nullglob
    local files=("$ROOT_DIR/$p/hooks/"check-*.sh)
    shopt -u nullglob
    if (( ${#files[@]} == 0 )); then
      echo "$p: no check-*.sh files matched"; rc=1; continue
    fi
    for f in "${files[@]}"; do
      matched=$((matched + 1))
      if ! bash -n "$f" 2>&1; then
        echo "bash -n failed: $f"; rc=1
      fi
    done
  done
  if (( matched == 0 )); then
    echo "no installer scripts matched any plugin"; rc=1
  fi
  return $rc
}

tc_installer_shellcheck() {
  local rc=0 p f
  for p in "${PLUGINS[@]}"; do
    shopt -s nullglob
    local files=("$ROOT_DIR/$p/hooks/"check-*.sh)
    shopt -u nullglob
    for f in "${files[@]}"; do
      # --shell=bash pins the dialect so a future shellcheck guess doesn't
      # drift; --severity=warning matches the project's policy without
      # spurious style noise.
      if ! shellcheck --shell=bash --severity=warning "$f"; then
        echo "shellcheck failed: $f"; rc=1
      fi
    done
  done
  return $rc
}

register_test "installer/bash-syntax" tc_installer_bash_syntax
register_test "installer/shellcheck" tc_installer_shellcheck
