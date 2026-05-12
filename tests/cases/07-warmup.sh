# Regal warmup tests (regal-lsp/lsp-proxy.js only).

_warmup_run() {
  node "$TESTS_DIR/helpers/warmup-suite.js" "$1"
}

tc_warmup_files_opened() { _warmup_run files-opened; }
tc_warmup_empty_tree()   { _warmup_run empty-tree; }
tc_warmup_no_section()   { _warmup_run no-warmup-section; }
tc_warmup_multi_ext()    { _warmup_run multi-extension; }

register_test "warmup/files-opened"      tc_warmup_files_opened
register_test "warmup/empty-tree"        tc_warmup_empty_tree
register_test "warmup/no-warmup-section" tc_warmup_no_section
register_test "warmup/multi-extension"   tc_warmup_multi_ext
