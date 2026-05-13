_installer_script() {
  # nullglob makes an unmatched glob expand to nothing instead of the literal
  # pattern, so missing installers surface as `not found` rather than a fake
  # path that downstream code parses as empty.
  shopt -s nullglob
  local files=("$ROOT_DIR/$1/hooks/"check-*.sh)
  shopt -u nullglob
  if (( ${#files[@]} == 0 )); then
    echo ""; return
  fi
  if (( ${#files[@]} > 1 )); then
    # Two installers in one plugin is ambiguous; flag rather than silently pick.
    echo "MULTIPLE:${files[*]}"; return
  fi
  printf '%s\n' "${files[0]}"
}

_installer_binary() {
  local script
  script=$(_installer_script "$1")
  [[ -n "$script" && "$script" != MULTIPLE:* && -f "$script" ]] || { echo ""; return 0; }
  awk -F'=' '/^BINARY=/ { gsub(/"/, "", $2); print $2; exit }' "$script"
}

tc_lsp_paths_are_safe() {
  local rc=0 p
  for p in "${PLUGINS[@]}"; do
    local f="$ROOT_DIR/$p/.lsp.json"
    if [[ ! -f "$f" ]]; then
      echo "$p: missing .lsp.json"; rc=1; continue
    fi
    while IFS= read -r s; do
      if [[ "$s" == /* ]]; then
        echo "$p .lsp.json: absolute path: $s"; rc=1
      elif [[ "$s" == */* && "$s" != '${CLAUDE_PLUGIN_ROOT}/'* ]]; then
        echo "$p .lsp.json: non-CLAUDE_PLUGIN_ROOT path: $s"; rc=1
      elif [[ "$s" == *'$'* && "$s" != '${CLAUDE_PLUGIN_ROOT}/'* ]]; then
        echo "$p .lsp.json: unknown variable expansion: $s"; rc=1
      fi
    done < <(jq -r 'to_entries[] | (.value.command, .value.args[]?)' "$f")
  done
  return $rc
}

_check_proxy_plugin() {
  local p="$1" lsp="$2" proxy_json="$3" installed_bin="$4"
  local rc=0 server0
  local expected_args='["${CLAUDE_PLUGIN_ROOT}/lsp-proxy.js","--config","${CLAUDE_PLUGIN_ROOT}/proxy.json"]'
  # Every languageId entry must agree on (command, args); validating only the
  # first jq-sorted entry would let entries 2+ silently drift.
  local mismatches
  mismatches=$(jq -r --arg expected_args "$expected_args" '
    to_entries[]
    | select(
        (.value.command != "node") or
        ((.value.args | tojson) != $expected_args)
      )
    | "  \(.key): command=\(.value.command) args=\(.value.args | tojson)"
  ' "$lsp")
  if [[ -n "$mismatches" ]]; then
    echo "$p: .lsp.json entries do not all agree on proxy invocation:"
    echo "$mismatches"
    echo "  expected: command=node args=$expected_args"
    rc=1
  fi
  [[ -f "$proxy_json" ]] || { echo "$p: ships lsp-proxy.js but no proxy.json"; return 1; }
  server0=$(jq -r '.server[0]' "$proxy_json")
  [[ "$server0" == "$installed_bin" ]] || { echo "$p: proxy.json server[0]='$server0' != installer BINARY='$installed_bin'"; rc=1; }
  return $rc
}

_check_direct_plugin() {
  local p="$1" lsp="$2" proxy_json="$3" installed_bin="$4"
  local rc=0 mismatches
  mismatches=$(jq -r --arg bin "$installed_bin" '
    to_entries[]
    | select(.value.command != $bin)
    | "  \(.key): command=\(.value.command)"
  ' "$lsp")
  if [[ -n "$mismatches" ]]; then
    echo "$p: .lsp.json entries do not all invoke installer BINARY='$installed_bin':"
    echo "$mismatches"
    rc=1
  fi
  [[ ! -f "$proxy_json" ]] || { echo "$p: has proxy.json but no lsp-proxy.js"; rc=1; }
  return $rc
}

tc_proxy_consistency() {
  local rc=0 p
  for p in "${PLUGINS[@]}"; do
    local lsp="$ROOT_DIR/$p/.lsp.json"
    local proxy_js="$ROOT_DIR/$p/lsp-proxy.js"
    local proxy_json="$ROOT_DIR/$p/proxy.json"
    local installed_bin
    installed_bin=$(_installer_binary "$p")
    if [[ -z "$installed_bin" ]]; then
      echo "$p: could not determine installer BINARY (missing or multiple check-*.sh)"
      rc=1; continue
    fi
    if [[ -f "$proxy_js" ]]; then
      _check_proxy_plugin "$p" "$lsp" "$proxy_json" "$installed_bin" || rc=1
    else
      _check_direct_plugin "$p" "$lsp" "$proxy_json" "$installed_bin" || rc=1
    fi
  done
  return $rc
}

# Every hooks.json command must end in `bash ${CLAUDE_PLUGIN_ROOT}/hooks/<file>`
# and that <file> must exist and be readable. Without this, a rename of
# check-*.sh on disk would break production silently — there's no other test
# that ties the hook entry back to the file.
tc_hooks_commands_point_to_existing_scripts() {
  local rc=0 p
  for p in "${PLUGINS[@]}"; do
    local hj="$ROOT_DIR/$p/hooks/hooks.json"
    if [[ ! -f "$hj" ]]; then
      echo "$p: missing hooks.json"; rc=1; continue
    fi
    local cmd
    while IFS= read -r cmd; do
      [[ -z "$cmd" ]] && continue
      # Accept either "bash ${CLAUDE_PLUGIN_ROOT}/hooks/<file>" or just the path.
      local rel
      rel=$(printf '%s' "$cmd" | sed -E 's|^bash[[:space:]]+\$\{CLAUDE_PLUGIN_ROOT\}/||; s|^\$\{CLAUDE_PLUGIN_ROOT\}/||')
      if [[ "$rel" == "$cmd" || "$rel" != hooks/* ]]; then
        echo "$p hooks.json: command does not reference \${CLAUDE_PLUGIN_ROOT}/hooks/...: $cmd"
        rc=1; continue
      fi
      # Strip any trailing arguments (`hooks/foo.sh --flag`).
      local script="${rel%% *}"
      local abs="$ROOT_DIR/$p/$script"
      if [[ ! -f "$abs" ]]; then
        echo "$p hooks.json: command references missing file: $abs"
        rc=1
      fi
    done < <(jq -r '.. | .command? // empty' "$hj")
  done
  return $rc
}

register_test "consistency/lsp-paths" tc_lsp_paths_are_safe
register_test "consistency/proxy-installer-match" tc_proxy_consistency
register_test "consistency/hooks-commands-resolve" tc_hooks_commands_point_to_existing_scripts
