tc_coverage_gate() {
  node "$TESTS_DIR/helpers/coverage-check.js" --threshold=80
}

register_test "coverage/gate-80-percent" tc_coverage_gate
