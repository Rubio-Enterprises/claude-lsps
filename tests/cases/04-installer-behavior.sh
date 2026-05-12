# shellcheck source=../helpers/mock-bin.sh
source "$TESTS_DIR/helpers/mock-bin.sh"

_meta_binary() {
  case "$1" in
    ansible-language-server) echo "ansible-language-server" ;;
    bash-language-server)    echo "bash-language-server" ;;
    cue-lsp)                 echo "cue" ;;
    pyright)                 echo "pyright-langserver" ;;
    regal-lsp)               echo "regal" ;;
    vtsls)                   echo "vtsls" ;;
  esac
}

# PATH is sandbox-only; see _provision_real_tools for the rationale.
_run_installer() {
  local sbx="$1" plugin="$2"
  local script="$sbx/check.sh"
  patch_installer "$plugin" "$script"
  env -i \
    PATH="$sbx/bin:$sbx/home/.local/bin" \
    HOME="$sbx/home" \
    TMPDIR="$sbx/tmp" \
    TMP_DIR="$TMP_DIR" \
    bash "$script"
}

_test_binary_present_noop() {
  local plugin="$1"
  local binary; binary=$(_meta_binary "$plugin")
  local sbx; sbx=$(new_sandbox "noop-$plugin")
  local log="$sbx/install.log"
  : > "$log"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$sbx/bin/$binary"
  chmod +x "$sbx/bin/$binary"
  if ! _run_installer "$sbx" "$plugin" >"$sbx/out.log" 2>&1; then
    echo "exit non-zero with binary present:"; cat "$sbx/out.log"; return 1
  fi
  if [[ -s "$log" ]]; then
    echo "expected zero install calls, got:"; cat "$log"; return 1
  fi
}

_test_primary_install_brew() {
  local plugin="$1" formula="$2" target="$3"
  local sbx; sbx=$(new_sandbox "brew-$plugin")
  local log="$sbx/install.log"
  : > "$log"
  make_install_mock "$sbx/bin" brew "$log" --target="$target"
  local out
  if ! _run_installer "$sbx" "$plugin" >"$sbx/out.log" 2>&1; then
    echo "installer exited non-zero:"; cat "$sbx/out.log"; return 1
  fi
  local calls; calls=$(wc -l <"$log")
  if (( calls != 1 )); then
    echo "expected exactly 1 install call, got $calls:"; cat "$log"; return 1
  fi
  local line; line=$(head -n1 "$log")
  if [[ "$line" != "brew install $formula" ]]; then
    echo "expected 'brew install $formula', got '$line'"; return 1
  fi
}

_test_primary_install_npm() {
  local plugin="$1" pkg="$2" target="$3"
  local sbx; sbx=$(new_sandbox "npm-$plugin")
  local log="$sbx/install.log"
  : > "$log"
  make_install_mock "$sbx/bin" npm "$log" --target="$target"
  if ! _run_installer "$sbx" "$plugin" >"$sbx/out.log" 2>&1; then
    echo "installer exited non-zero:"; cat "$sbx/out.log"; return 1
  fi
  local calls; calls=$(wc -l <"$log")
  if (( calls != 1 )); then
    echo "expected exactly 1 install call, got $calls:"; cat "$log"; return 1
  fi
  local line; line=$(head -n1 "$log")
  if [[ "$line" != "npm install -g $pkg" ]]; then
    echo "expected 'npm install -g $pkg', got '$line'"; return 1
  fi
}

_test_cue_binary_install() {
  local sbx; sbx=$(new_sandbox "cue-binary")
  local log="$sbx/install.log"
  : > "$log"
  make_curl_mock "$sbx/bin" "$log"
  make_tar_mock  "$sbx/bin" "$log"
  if ! _run_installer "$sbx" cue-lsp >"$sbx/out.log" 2>&1; then
    echo "cue binary install exited non-zero:"; cat "$sbx/out.log"; return 1
  fi
  if ! grep -q '^curl ' "$log"; then echo "no curl call recorded"; cat "$log"; return 1; fi
  if ! grep -q '^tar ' "$log";  then echo "no tar call recorded"; cat "$log"; return 1; fi
  local curl_calls tar_calls
  curl_calls=$(grep -c '^curl ' "$log")
  tar_calls=$(grep -c '^tar ' "$log")
  if (( curl_calls != 1 || tar_calls != 1 )); then
    echo "expected 1 curl + 1 tar, got curl=$curl_calls tar=$tar_calls"
    cat "$log"
    return 1
  fi
  # `xz` must appear as its own argument, not as a substring of another flag.
  if ! grep -E '^tar( .*)? xz( |$)' "$log" >/dev/null; then
    echo "tar call missing 'xz' flag:"; cat "$log"; return 1
  fi
}

_test_regal_binary_install() {
  local sbx; sbx=$(new_sandbox "regal-binary")
  local log="$sbx/install.log"
  : > "$log"
  make_curl_mock "$sbx/bin" "$log"
  if ! _run_installer "$sbx" regal-lsp >"$sbx/out.log" 2>&1; then
    echo "regal binary install exited non-zero:"; cat "$sbx/out.log"; return 1
  fi
  local curl_calls; curl_calls=$(grep -c '^curl ' "$log")
  if (( curl_calls != 1 )); then
    echo "expected exactly 1 curl call, got $curl_calls:"; cat "$log"; return 1
  fi
  # grep -F so $sbx isn't interpreted as a regex.
  if ! grep -F -- "-o $sbx/home/.local/bin/regal" "$log" >/dev/null; then
    echo "curl call did not target the expected install path:"; cat "$log"; return 1
  fi
}

_test_all_absent_fails() {
  local plugin="$1"
  local sbx; sbx=$(new_sandbox "absent-$plugin")
  local rc=0
  _run_installer "$sbx" "$plugin" >"$sbx/out.log" 2>"$sbx/err.log" || rc=$?
  if (( rc == 0 )); then
    echo "expected non-zero exit; got 0"
    cat "$sbx/out.log" "$sbx/err.log"
    return 1
  fi
  if ! grep -iE 'Neither Homebrew nor npm|Install one of them' "$sbx/out.log" "$sbx/err.log" >/dev/null; then
    echo "expected 'Neither Homebrew nor npm' message; got:"
    echo "--- stdout ---"; cat "$sbx/out.log"
    echo "--- stderr ---"; cat "$sbx/err.log"
    return 1
  fi
}

tc_install_noop_ansible()  { _test_binary_present_noop ansible-language-server; }
tc_install_noop_bash()     { _test_binary_present_noop bash-language-server; }
tc_install_noop_cue()      { _test_binary_present_noop cue-lsp; }
tc_install_noop_pyright()  { _test_binary_present_noop pyright; }
tc_install_noop_regal()    { _test_binary_present_noop regal-lsp; }
tc_install_noop_vtsls()    { _test_binary_present_noop vtsls; }

tc_install_brew_ansible()  { _test_primary_install_brew ansible-language-server ansible-language-server ansible-language-server; }
tc_install_brew_bash()     { _test_primary_install_brew bash-language-server bash-language-server bash-language-server; }
tc_install_brew_cue()      { _test_primary_install_brew cue-lsp cue-lang/tap/cue cue; }
tc_install_brew_pyright()  { _test_primary_install_brew pyright pyright pyright-langserver; }
tc_install_brew_vtsls()    { _test_primary_install_brew vtsls vtsls vtsls; }

tc_install_npm_ansible()   { _test_primary_install_npm ansible-language-server "@ansible/ansible-language-server" ansible-language-server; }
tc_install_npm_bash()      { _test_primary_install_npm bash-language-server bash-language-server bash-language-server; }
tc_install_npm_pyright()   { _test_primary_install_npm pyright pyright pyright-langserver; }
tc_install_npm_vtsls()     { _test_primary_install_npm vtsls "@vtsls/language-server" vtsls; }

tc_install_binary_cue()    { _test_cue_binary_install; }
tc_install_binary_regal()  { _test_regal_binary_install; }

tc_install_absent_ansible() { _test_all_absent_fails ansible-language-server; }
tc_install_absent_bash()    { _test_all_absent_fails bash-language-server; }
tc_install_absent_pyright() { _test_all_absent_fails pyright; }
tc_install_absent_vtsls()   { _test_all_absent_fails vtsls; }

# Regal's brew branch only runs on Darwin (Linux forces the binary path).
# Mock uname so the Darwin code path is exercised on any host.
tc_install_darwin_regal() {
  local sbx; sbx=$(new_sandbox "darwin-regal")
  local log="$sbx/install.log"; : >"$log"
  make_uname_mock "$sbx/bin" Darwin arm64
  make_install_mock "$sbx/bin" brew "$log" --target=regal
  if ! _run_installer "$sbx" regal-lsp >"$sbx/out.log" 2>&1; then
    echo "darwin regal install exited non-zero:"; cat "$sbx/out.log"; return 1
  fi
  local calls; calls=$(wc -l <"$log")
  if (( calls != 1 )); then
    echo "expected exactly 1 install call, got $calls:"; cat "$log"; return 1
  fi
  if grep -q '^curl ' "$log"; then
    echo "Darwin path unexpectedly invoked curl:"; cat "$log"; return 1
  fi
  local line; line=$(head -n1 "$log")
  if [[ "$line" != "brew install styrainc/tap/regal" ]]; then
    echo "expected 'brew install styrainc/tap/regal', got '$line'"; return 1
  fi
}

tc_install_mkdir_lock_fallback() {
  local sbx; sbx=$(new_sandbox "mkdir-lock-ansible")
  local log="$sbx/install.log"; : >"$log"
  remove_flock "$sbx/bin"
  make_install_mock "$sbx/bin" brew "$log" --target=ansible-language-server
  if ! _run_installer "$sbx" ansible-language-server >"$sbx/out.log" 2>&1; then
    echo "mkdir-lock fallback exited non-zero:"; cat "$sbx/out.log"; return 1
  fi
  local calls; calls=$(wc -l <"$log")
  if (( calls != 1 )); then
    echo "expected 1 install call via mkdir-lock branch, got $calls:"; cat "$log"; return 1
  fi
  # The mkdir branch creates "$LOCK_FILE.d" (a directory, cleaned up via EXIT
  # trap); the flock branch creates the bare "$LOCK_FILE" (a file, via `9>`).
  # Presence of either tells us which branch actually ran.
  if compgen -G "$sbx/lock-*.lock.d" >/dev/null; then
    echo "mkdir lock dir was not cleaned up:"
    compgen -G "$sbx/lock-*.lock.d"
    return 1
  fi
  if compgen -G "$sbx/lock-*.lock" >/dev/null; then
    echo "flock branch ran instead of mkdir branch (.lock file exists in sandbox):"
    compgen -G "$sbx/lock-*.lock"
    return 1
  fi
}

tc_install_failure_propagates() {
  local sbx; sbx=$(new_sandbox "fail-ansible")
  local log="$sbx/install.log"; : >"$log"
  make_install_mock "$sbx/bin" brew "$log" --exit=1
  local rc=0
  _run_installer "$sbx" ansible-language-server >"$sbx/out.log" 2>&1 || rc=$?
  if (( rc == 0 )); then
    echo "expected non-zero exit on install failure; got 0"
    cat "$sbx/out.log"
    return 1
  fi
  if ! grep -F 'brew install failed' "$sbx/out.log" >/dev/null; then
    echo "expected 'brew install failed' message; got:"; cat "$sbx/out.log"; return 1
  fi
}

tc_install_post_check_missing_binary() {
  local sbx; sbx=$(new_sandbox "no-binary-after-ansible")
  local log="$sbx/install.log"; : >"$log"
  make_install_mock "$sbx/bin" brew "$log"
  local rc=0
  _run_installer "$sbx" ansible-language-server >"$sbx/out.log" 2>&1 || rc=$?
  if (( rc == 0 )); then
    echo "expected non-zero exit when binary missing post-install; got 0"
    cat "$sbx/out.log"
    return 1
  fi
  if ! grep -F 'Not in PATH after install' "$sbx/out.log" >/dev/null; then
    echo "expected post-install message; got:"; cat "$sbx/out.log"; return 1
  fi
}

register_test "installer/noop-ansible"     tc_install_noop_ansible
register_test "installer/noop-bash"        tc_install_noop_bash
register_test "installer/noop-cue"         tc_install_noop_cue
register_test "installer/noop-pyright"     tc_install_noop_pyright
register_test "installer/noop-regal"       tc_install_noop_regal
register_test "installer/noop-vtsls"       tc_install_noop_vtsls

register_test "installer/brew-ansible"     tc_install_brew_ansible
register_test "installer/brew-bash"        tc_install_brew_bash
register_test "installer/brew-cue"         tc_install_brew_cue
register_test "installer/brew-pyright"     tc_install_brew_pyright
register_test "installer/brew-vtsls"       tc_install_brew_vtsls

register_test "installer/npm-ansible"      tc_install_npm_ansible
register_test "installer/npm-bash"         tc_install_npm_bash
register_test "installer/npm-pyright"      tc_install_npm_pyright
register_test "installer/npm-vtsls"        tc_install_npm_vtsls

register_test "installer/binary-cue"       tc_install_binary_cue
register_test "installer/binary-regal"     tc_install_binary_regal

register_test "installer/absent-ansible"   tc_install_absent_ansible
register_test "installer/absent-bash"      tc_install_absent_bash
register_test "installer/absent-pyright"   tc_install_absent_pyright
register_test "installer/absent-vtsls"     tc_install_absent_vtsls

register_test "installer/darwin-regal"           tc_install_darwin_regal
register_test "installer/mkdir-lock-fallback"    tc_install_mkdir_lock_fallback
register_test "installer/failure-propagates"     tc_install_failure_propagates
register_test "installer/post-check-missing"     tc_install_post_check_missing_binary
