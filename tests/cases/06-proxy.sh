# Proxy framing tests, executed via a Node harness.

_proxy_run() {
  local scenario="$1"
  node "$TESTS_DIR/helpers/proxy-suite.js" "$scenario"
}

tc_proxy_passthrough()          { _proxy_run passthrough; }
tc_proxy_blocked_request()      { _proxy_run blocked-request; }
tc_proxy_blocked_notification() { _proxy_run blocked-notification; }
tc_proxy_auto_ack_register()    { _proxy_run auto-ack-register; }
tc_proxy_auto_ack_unregister()  { _proxy_run auto-ack-unregister; }
tc_proxy_auto_ack_configuration() { _proxy_run auto-ack-configuration; }
tc_proxy_auto_ack_workdone()    { _proxy_run auto-ack-workdone; }
tc_proxy_split_buffer()         { _proxy_run split-buffer; }
tc_proxy_sigterm()              { _proxy_run sigterm; }
tc_proxy_sigint()               { _proxy_run sigint; }
tc_proxy_exit_code()            { _proxy_run exit-code-propagated; }
tc_proxy_stdin_eof()            { _proxy_run stdin-eof; }
tc_proxy_config_missing()       { _proxy_run config-missing; }
tc_proxy_config_unreadable()    { _proxy_run config-unreadable; }
tc_proxy_config_empty_server()  { _proxy_run config-empty-server; }

register_test "proxy/passthrough"              tc_proxy_passthrough
register_test "proxy/blocked-request"          tc_proxy_blocked_request
register_test "proxy/blocked-notification"     tc_proxy_blocked_notification
register_test "proxy/auto-ack-register"        tc_proxy_auto_ack_register
register_test "proxy/auto-ack-unregister"      tc_proxy_auto_ack_unregister
register_test "proxy/auto-ack-configuration"   tc_proxy_auto_ack_configuration
register_test "proxy/auto-ack-workdone"        tc_proxy_auto_ack_workdone
register_test "proxy/split-buffer"             tc_proxy_split_buffer
register_test "proxy/sigterm"                  tc_proxy_sigterm
register_test "proxy/sigint"                   tc_proxy_sigint
register_test "proxy/exit-code"                tc_proxy_exit_code
register_test "proxy/stdin-eof"                tc_proxy_stdin_eof
register_test "proxy/config-missing"           tc_proxy_config_missing
register_test "proxy/config-unreadable"        tc_proxy_config_unreadable
register_test "proxy/config-empty-server"      tc_proxy_config_empty_server
