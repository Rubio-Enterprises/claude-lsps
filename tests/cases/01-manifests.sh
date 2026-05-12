tc_manifests_json_valid() {
  local rc=0
  local f
  for f in "$ROOT_DIR"/*/.claude-plugin/plugin.json \
           "$ROOT_DIR"/*/.lsp.json \
           "$ROOT_DIR"/*/hooks/hooks.json \
           "$ROOT_DIR"/*/proxy.json \
           "$ROOT_DIR/.claude-plugin/marketplace.json"; do
    [[ -e "$f" ]] || continue
    if ! jq -e . "$f" >/dev/null 2>&1; then
      echo "invalid JSON: $f"
      rc=1
    fi
  done
  return $rc
}

tc_plugin_json_required_keys() {
  local rc=0 p k
  for p in "${PLUGINS[@]}"; do
    local f="$ROOT_DIR/$p/.claude-plugin/plugin.json"
    if [[ ! -f "$f" ]]; then
      echo "missing $f"; rc=1; continue
    fi
    for k in name version description; do
      local t v
      t=$(jq -r --arg k "$k" '.[$k] | type' "$f")
      v=$(jq -r --arg k "$k" '.[$k] // empty' "$f")
      if [[ "$t" != "string" || -z "$v" ]]; then
        echo "$p plugin.json: missing/non-string $k (type=$t)"
        rc=1
      fi
    done
  done
  return $rc
}

tc_lsp_json_structure() {
  local rc=0 p
  for p in "${PLUGINS[@]}"; do
    local f="$ROOT_DIR/$p/.lsp.json"
    if [[ ! -f "$f" ]]; then
      echo "missing $f"; rc=1; continue
    fi
    local count
    count=$(jq 'keys | length' "$f")
    if (( count < 1 )); then
      echo "$p .lsp.json: no languageId keys"; rc=1; continue
    fi
    local check
    check=$(jq '
      [to_entries[] | .value | (
        (.command | type == "string") and
        (.args | type == "array") and
        ((.args // []) | all(type == "string")) and
        (.extensionToLanguage | type == "object") and
        ((.extensionToLanguage | to_entries) | all(
          (.key | startswith(".")) and (.value | type == "string")
        ))
      )] | all
    ' "$f")
    if [[ "$check" != "true" ]]; then
      echo "$p .lsp.json: structure check failed"
      jq . "$f"
      rc=1
    fi
  done
  return $rc
}

tc_hooks_json_structure() {
  local rc=0 p
  for p in "${PLUGINS[@]}"; do
    local f="$ROOT_DIR/$p/hooks/hooks.json"
    if [[ ! -f "$f" ]]; then
      echo "missing $f"; rc=1; continue
    fi
    local check
    check=$(jq '
      (.hooks.SessionStart | type == "array") and
      (.hooks.SessionStart | all(
        (.hooks | type) == "array" and
        (.hooks | all((.command | type) == "string"))
      ))
    ' "$f")
    if [[ "$check" != "true" ]]; then
      echo "$p hooks.json: SessionStart hooks[].command not all strings"
      rc=1
    fi
  done
  return $rc
}

tc_proxy_json_structure() {
  local rc=0 p
  for p in "${PLUGINS[@]}"; do
    local f="$ROOT_DIR/$p/proxy.json"
    [[ -f "$f" ]] || continue
    local check
    check=$(jq '
      (.server | type == "array") and
      ((.server | length) > 0) and
      (.server | all(type == "string")) and
      (.blocked | type == "array") and
      (.blocked | all(type == "string")) and
      (if has("warmup") and (.warmup != null) then
        (.warmup.extensions | type == "array") and
        (.warmup.extensions | all(type == "string")) and
        (.warmup.exclude | type == "array") and
        (.warmup.exclude | all(type == "string"))
       else true end)
    ' "$f")
    if [[ "$check" != "true" ]]; then
      echo "$p proxy.json: structure check failed"
      jq . "$f"
      rc=1
    fi
  done
  return $rc
}

tc_marketplace_matches_plugins() {
  local mp="$ROOT_DIR/.claude-plugin/marketplace.json"
  local rc=0

  local sources actual
  sources=$(jq -r '.plugins[].source | sub("^\\./"; "")' "$mp" | LC_ALL=C sort)
  actual=$(printf '%s\n' "${PLUGINS[@]}" | LC_ALL=C sort)
  if [[ "$sources" != "$actual" ]]; then
    echo "marketplace plugin sources != plugin dirs"
    diff <(echo "$sources") <(echo "$actual") || true
    rc=1
  fi

  while IFS=$'\t' read -r src name version description; do
    local sub="${src#./}"
    local pj="$ROOT_DIR/$sub/.claude-plugin/plugin.json"
    if [[ ! -f "$pj" ]]; then
      echo "marketplace references missing plugin: $src"; rc=1; continue
    fi
    local pjn pjv pjd
    pjn=$(jq -r '.name' "$pj")
    pjv=$(jq -r '.version' "$pj")
    pjd=$(jq -r '.description' "$pj")
    if [[ "$name" != "$pjn" || "$version" != "$pjv" || "$description" != "$pjd" ]]; then
      echo "marketplace[$src] mismatch:"
      echo "  marketplace: name=$name version=$version description=$description"
      echo "  plugin.json: name=$pjn version=$pjv description=$pjd"
      rc=1
    fi
  done < <(jq -r '.plugins[] | [.source, .name, .version, .description] | @tsv' "$mp")
  return $rc
}

register_test "manifests/json-valid" tc_manifests_json_valid
register_test "manifests/plugin-keys" tc_plugin_json_required_keys
register_test "manifests/lsp-structure" tc_lsp_json_structure
register_test "manifests/hooks-structure" tc_hooks_json_structure
register_test "manifests/proxy-structure" tc_proxy_json_structure
register_test "manifests/marketplace-match" tc_marketplace_matches_plugins
