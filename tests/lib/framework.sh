# shellcheck shell=bash
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
    # Prefix the log with the test index so two test names that differ only in
    # punctuation can't collide on disk (`a/b` and `a_b` both collapse via tr).
    local sanitized log
    sanitized=$(printf '%s' "$name" | tr '/ ' '__')
    log=$(printf '%s/%04d-%s.log' "$TMP_DIR" "$i" "$sanitized")
    local rc=0
    # The subshell explicitly disables -e so cases can use the rc-aggregation
    # idiom (`rc=1; ... return $rc`) inherited from run.sh's `set -e`. Run-level
    # fail-fast remains via `|| rc=$?` below.
    (
      set +e
      "$fn"
    ) >"$log" 2>&1 || rc=$?
    if ((rc == 0)); then
      passed=$((passed + 1))
      printf '[%d/%d] %s ... PASS\n' "$((i + 1))" "$total" "$name"
    else
      failed=$((failed + 1))
      failed_names+=("$name")
      printf '[%d/%d] %s ... FAIL (rc=%d)\n' "$((i + 1))" "$total" "$name" "$rc"
      sed 's/^/    /' "$log" || true
    fi
  done

  if ((failed == 0)); then
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
