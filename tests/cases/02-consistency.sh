_installer_script() {
  local files=("$ROOT_DIR/$1/hooks/"check-*.sh)
  printf '%s\n' "${files[0]}"
}

_installer_binary() {
  local script
  script=$(_installer_script "$1")
  [[ -f "$script" ]] || { echo ""; return; }
  awk -F'=' '/^BINARY=/ { gsub(/"/, "", $2); print $2; exit }' "$script"
}

tc_lsp_paths_are_safe() {
  local rc=0 p
  for p in "${PLUGINS[@]}"; do
    local f="$ROOT_DIR/$p/.lsp.json"
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
  local rc=0 cmd args_json server0
  local expected='["${CLAUDE_PLUGIN_ROOT}/lsp-proxy.js","--config","${CLAUDE_PLUGIN_ROOT}/proxy.json"]'
  cmd=$(jq -r 'to_entries[0].value.command' "$lsp")
  args_json=$(jq -c 'to_entries[0].value.args' "$lsp")
  [[ "$cmd" == "node" ]] || { echo "$p: ships lsp-proxy.js but .lsp.json command is '$cmd' (expected 'node')"; rc=1; }
  [[ "$args_json" == "$expected" ]] || { echo "$p: .lsp.json args mismatch"; echo "  got:      $args_json"; echo "  expected: $expected"; rc=1; }
  [[ -f "$proxy_json" ]] || { echo "$p: ships lsp-proxy.js but no proxy.json"; return 1; }
  server0=$(jq -r '.server[0]' "$proxy_json")
  [[ "$server0" == "$installed_bin" ]] || { echo "$p: proxy.json server[0]='$server0' != installer BINARY='$installed_bin'"; rc=1; }
  return $rc
}

_check_direct_plugin() {
  local p="$1" lsp="$2" proxy_json="$3" installed_bin="$4"
  local rc=0 cmd
  cmd=$(jq -r 'to_entries[0].value.command' "$lsp")
  [[ "$cmd" == "$installed_bin" ]] || { echo "$p: .lsp.json command='$cmd' != installer BINARY='$installed_bin'"; rc=1; }
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
      echo "$p: could not determine installer BINARY"; rc=1; continue
    fi
    if [[ -f "$proxy_js" ]]; then
      _check_proxy_plugin "$p" "$lsp" "$proxy_json" "$installed_bin" || rc=1
    else
      _check_direct_plugin "$p" "$lsp" "$proxy_json" "$installed_bin" || rc=1
    fi
  done
  return $rc
}

register_test "consistency/lsp-paths" tc_lsp_paths_are_safe
register_test "consistency/proxy-installer-match" tc_proxy_consistency
