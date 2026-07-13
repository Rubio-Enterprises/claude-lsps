# shellcheck shell=bash
_proxy_run() {
  local scenario="$1"
  node "$TESTS_DIR/helpers/proxy-suite.js" "$scenario"
}

tc_proxy_passthrough() { _proxy_run passthrough; }
tc_proxy_passthrough_s2c() { _proxy_run passthrough-server-to-client; }
tc_proxy_blocked_request() { _proxy_run blocked-request; }
tc_proxy_blocked_notification() { _proxy_run blocked-notification; }
tc_proxy_malformed_header() { _proxy_run malformed-header-forwarded; }
tc_proxy_unparseable_body() { _proxy_run unparseable-body-forwarded; }
tc_proxy_auto_ack_register() { _proxy_run auto-ack-register; }
tc_proxy_auto_ack_unregister() { _proxy_run auto-ack-unregister; }
tc_proxy_auto_ack_configuration() { _proxy_run auto-ack-configuration; }
tc_proxy_auto_ack_workdone() { _proxy_run auto-ack-workdone; }
tc_proxy_server_req_forwarded() { _proxy_run server-req-forwarded; }
tc_proxy_split_buffer() { _proxy_run split-buffer; }
tc_proxy_sigterm() { _proxy_run sigterm; }
tc_proxy_sigint() { _proxy_run sigint; }
tc_proxy_exit_code() { _proxy_run exit-code-propagated; }
tc_proxy_stdin_eof() { _proxy_run stdin-eof; }
tc_proxy_config_missing() { _proxy_run config-missing; }
tc_proxy_config_unreadable() { _proxy_run config-unreadable; }
tc_proxy_config_empty_server() { _proxy_run config-empty-server; }
tc_proxy_child_spawn_error() { _proxy_run child-spawn-error; }
tc_proxy_regal_passthrough() { _proxy_run regal-passthrough; }
tc_proxy_regal_blocked() { _proxy_run regal-blocked-request; }
tc_proxy_sync_inject() { _proxy_run sync-injects-on-disk-edit; }
tc_proxy_sync_reconcile() { _proxy_run sync-reconciles-client-didchange; }
tc_proxy_sync_incremental() { _proxy_run sync-incremental-disables; }
tc_proxy_sync_noop_close() { _proxy_run sync-noop-and-didclose; }
tc_proxy_sync_disabled() { _proxy_run sync-disabled-by-config; }
tc_proxy_sync_warmup() { _proxy_run sync-tracks-warmup-opens; }
tc_proxy_sync_delete() { _proxy_run sync-delete-and-reappear; }
tc_proxy_sync_rebase() { _proxy_run sync-version-rebase; }
tc_proxy_stdin_eof_exit() { _proxy_run stdin-eof-exit-code; }
tc_proxy_warmup_dedup() { _proxy_run warmup-skips-client-opened; }
tc_proxy_warmup_translate() { _proxy_run warmup-then-client-open-translated; }

register_test "proxy/passthrough" tc_proxy_passthrough
register_test "proxy/passthrough-server-to-client" tc_proxy_passthrough_s2c
register_test "proxy/blocked-request" tc_proxy_blocked_request
register_test "proxy/blocked-notification" tc_proxy_blocked_notification
register_test "proxy/malformed-header" tc_proxy_malformed_header
register_test "proxy/unparseable-body" tc_proxy_unparseable_body
register_test "proxy/auto-ack-register" tc_proxy_auto_ack_register
register_test "proxy/auto-ack-unregister" tc_proxy_auto_ack_unregister
register_test "proxy/auto-ack-configuration" tc_proxy_auto_ack_configuration
register_test "proxy/auto-ack-workdone" tc_proxy_auto_ack_workdone
register_test "proxy/server-req-forwarded" tc_proxy_server_req_forwarded
register_test "proxy/split-buffer" tc_proxy_split_buffer
register_test "proxy/sigterm" tc_proxy_sigterm
register_test "proxy/sigint" tc_proxy_sigint
register_test "proxy/exit-code" tc_proxy_exit_code
register_test "proxy/stdin-eof" tc_proxy_stdin_eof
register_test "proxy/config-missing" tc_proxy_config_missing
register_test "proxy/config-unreadable" tc_proxy_config_unreadable
register_test "proxy/config-empty-server" tc_proxy_config_empty_server
register_test "proxy/child-spawn-error" tc_proxy_child_spawn_error
register_test "proxy/regal-passthrough" tc_proxy_regal_passthrough
register_test "proxy/regal-blocked-request" tc_proxy_regal_blocked
register_test "proxy/sync-injects-on-disk-edit" tc_proxy_sync_inject
register_test "proxy/sync-reconciles-client-didchange" tc_proxy_sync_reconcile
register_test "proxy/sync-incremental-disables" tc_proxy_sync_incremental
register_test "proxy/sync-noop-and-didclose" tc_proxy_sync_noop_close
register_test "proxy/sync-disabled-by-config" tc_proxy_sync_disabled
register_test "proxy/sync-tracks-warmup-opens" tc_proxy_sync_warmup
register_test "proxy/sync-delete-and-reappear" tc_proxy_sync_delete
register_test "proxy/sync-version-rebase" tc_proxy_sync_rebase
register_test "proxy/stdin-eof-exit-code" tc_proxy_stdin_eof_exit
register_test "proxy/warmup-skips-client-opened" tc_proxy_warmup_dedup
register_test "proxy/warmup-then-client-open-translated" tc_proxy_warmup_translate
