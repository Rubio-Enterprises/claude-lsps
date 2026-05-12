# Cross-file consistency between .lsp.json, proxy.json, and the installer script.

_installer_script() {
  local plugin="$1"
  ls "$ROOT_DIR/$plugin/hooks/"check-*.sh 2>/dev/null | head -n1
}

_installer_binary() {
  local script
  script=$(_installer_script "$1")
  [[ -n "$script" && -f "$script" ]] || { echo ""; return; }
  # Extract BINARY="..." from the first occurrence.
  awk -F'=' '/^BINARY=/ { gsub(/"/, "", $2); print $2; exit }' "$script"
}

tc_lsp_paths_are_safe() {
  local rc=0 p
  for p in "${PLUGINS[@]}"; do
    local f="$ROOT_DIR/$p/.lsp.json"
    while IFS= read -r s; do
      # Reject absolute paths and relative paths with '/' not anchored at ${CLAUDE_PLUGIN_ROOT}.
      if [[ "$s" == /* ]]; then
        echo "$p .lsp.json: absolute path: $s"
        rc=1
        continue
      fi
      if [[ "$s" == */* && "$s" != '${CLAUDE_PLUGIN_ROOT}/'* ]]; then
        echo "$p .lsp.json: non-CLAUDE_PLUGIN_ROOT path: $s"
        rc=1
        continue
      fi
      # Variables other than CLAUDE_PLUGIN_ROOT are not allowed.
      if [[ "$s" == *'$'* && "$s" != '${CLAUDE_PLUGIN_ROOT}/'* ]]; then
        echo "$p .lsp.json: unknown variable expansion: $s"
        rc=1
      fi
    done < <(jq -r 'to_entries[] | (.value.command, .value.args[]?)' "$f")
  done
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
      echo "$p: could not determine installer BINARY"
      rc=1
      continue
    fi

    if [[ -f "$proxy_js" ]]; then
      # Proxy plugin: .lsp.json must invoke `node ${ROOT}/lsp-proxy.js --config ${ROOT}/proxy.json`.
      local cmd args_json
      cmd=$(jq -r 'to_entries[0].value.command' "$lsp")
      if [[ "$cmd" != "node" ]]; then
        echo "$p: ships lsp-proxy.js but .lsp.json command is '$cmd' (expected 'node')"
        rc=1
      fi
      args_json=$(jq -c 'to_entries[0].value.args' "$lsp")
      local expected='["${CLAUDE_PLUGIN_ROOT}/lsp-proxy.js","--config","${CLAUDE_PLUGIN_ROOT}/proxy.json"]'
      if [[ "$args_json" != "$expected" ]]; then
        echo "$p: .lsp.json args mismatch"
        echo "  got:      $args_json"
        echo "  expected: $expected"
        rc=1
      fi
      if [[ ! -f "$proxy_json" ]]; then
        echo "$p: ships lsp-proxy.js but no proxy.json"
        rc=1
        continue
      fi
      local server0
      server0=$(jq -r '.server[0]' "$proxy_json")
      if [[ "$server0" != "$installed_bin" ]]; then
        echo "$p: proxy.json server[0]='$server0' != installer BINARY='$installed_bin'"
        rc=1
      fi
    else
      # No proxy: .lsp.json command must match installer BINARY.
      local cmd
      cmd=$(jq -r 'to_entries[0].value.command' "$lsp")
      if [[ "$cmd" != "$installed_bin" ]]; then
        echo "$p: .lsp.json command='$cmd' != installer BINARY='$installed_bin'"
        rc=1
      fi
      if [[ -f "$proxy_json" ]]; then
        echo "$p: has proxy.json but no lsp-proxy.js"
        rc=1
      fi
    fi
  done
  return $rc
}

register_test "consistency/lsp-paths" tc_lsp_paths_are_safe
register_test "consistency/proxy-installer-match" tc_proxy_consistency
