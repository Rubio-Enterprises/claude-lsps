# Test framework. Sourced by tests/run.sh.
# Tests register themselves via `register_test "<name>" "<fn>"`.

# Use indexed arrays to preserve registration order.
TEST_NAMES=()
TEST_FNS=()

register_test() {
  TEST_NAMES+=("$1")
  TEST_FNS+=("$2")
}

run_all() {
  local total="${#TEST_NAMES[@]}"
  local passed=0
  local failed=0
  local failed_names=()
  local i
  for ((i = 0; i < total; i++)); do
    local name="${TEST_NAMES[$i]}"
    local fn="${TEST_FNS[$i]}"
    local log="$TMP_DIR/$(printf '%s' "$name" | tr '/ ' '__').log"
    local rc=0
    ( "$fn" ) >"$log" 2>&1 || rc=$?
    if (( rc == 0 )); then
      passed=$((passed + 1))
      printf '[%d/%d] %s ... PASS\n' "$((i + 1))" "$total" "$name"
    else
      failed=$((failed + 1))
      failed_names+=("$name")
      printf '[%d/%d] %s ... FAIL (rc=%d)\n' "$((i + 1))" "$total" "$name" "$rc"
      sed 's/^/    /' "$log" || true
    fi
  done

  if (( failed == 0 )); then
    printf 'PASS: %d tests, 0 failures\n' "$total"
    return 0
  else
    local list
    list=$(printf '%s, ' "${failed_names[@]}")
    list=${list%, }
    printf 'FAIL: %d tests, %d failures: %s\n' "$total" "$failed" "$list"
    return 1
  fi
}
