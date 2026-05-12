# Final test: enforce a minimum line-coverage threshold on the two
# lsp-proxy.js files. Runs after every other test so NODE_V8_COVERAGE has
# accumulated data from all the Node subprocesses the harness spawned.

tc_coverage_gate() {
  node "$TESTS_DIR/helpers/coverage-check.js" --threshold=80
}

register_test "coverage/gate-80-percent" tc_coverage_gate
