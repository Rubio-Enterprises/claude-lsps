# shellcheck shell=bash

_live_run() {
  node "$TESTS_DIR/helpers/live-suite.js" "$1"
}

LIVE_SKIPPED=()

_register_if_present() {
  local binary="$1" name="$2" fn="$3"
  if command -v "$binary" >/dev/null 2>&1; then
    register_test "$name" "$fn"
  else
    LIVE_SKIPPED+=("$name (missing: $binary)")
  fi
}

tc_live_bash_clean()       { _live_run bash-clean; }
tc_live_bash_broken()      { _live_run bash-broken; }
_register_if_present bash-language-server "live/bash-clean"  tc_live_bash_clean
_register_if_present bash-language-server "live/bash-broken" tc_live_bash_broken

tc_live_pyright_clean()    { _live_run pyright-clean; }
tc_live_pyright_broken()   { _live_run pyright-broken; }
_register_if_present pyright-langserver "live/pyright-clean"  tc_live_pyright_clean
_register_if_present pyright-langserver "live/pyright-broken" tc_live_pyright_broken

tc_live_vtsls_clean()      { _live_run vtsls-clean; }
tc_live_vtsls_broken()     { _live_run vtsls-broken; }
_register_if_present vtsls "live/vtsls-clean"  tc_live_vtsls_clean
_register_if_present vtsls "live/vtsls-broken" tc_live_vtsls_broken

tc_live_cue_clean()        { _live_run cue-clean; }
_register_if_present cue "live/cue-clean"  tc_live_cue_clean
# cue-broken intentionally omitted: cue lsp serve v0.16 does not publish
# diagnostics. Restore when upstream gains support (live-suite.js note).

tc_live_ansible_clean()    { _live_run ansible-clean; }
tc_live_ansible_broken()   { _live_run ansible-broken; }
_register_if_present ansible-language-server "live/ansible-clean"  tc_live_ansible_clean
_register_if_present ansible-language-server "live/ansible-broken" tc_live_ansible_broken

tc_live_regal_clean()      { _live_run regal-clean; }
tc_live_regal_broken()     { _live_run regal-broken; }
tc_live_regal_warmup()     { _live_run regal-warmup; }
_register_if_present regal "live/regal-clean"  tc_live_regal_clean
_register_if_present regal "live/regal-broken" tc_live_regal_broken
_register_if_present regal "live/regal-warmup" tc_live_regal_warmup

tc_live_skip_report() {
  if ((${#LIVE_SKIPPED[@]} > 0)); then
    printf 'live-suite skipped %d test(s):\n' "${#LIVE_SKIPPED[@]}"
    printf '  - %s\n' "${LIVE_SKIPPED[@]}"
  else
    printf 'live-suite: all LSP binaries present\n'
  fi
  return 0
}
register_test "live/skip-report" tc_live_skip_report
