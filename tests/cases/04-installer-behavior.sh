# Behavior of each check-*.sh under a mocked PATH.

# shellcheck source=../helpers/mock-bin.sh
source "$TESTS_DIR/helpers/mock-bin.sh"

# Per-plugin metadata:
#   binary, primary install method, expected install-call pattern.
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

# Run a patched installer in an isolated sandbox.
# Args: <sandbox> <plugin>
# Uses globals SBX_EXTRA_BIN to additionally prepend dirs (optional).
_run_installer() {
  local sbx="$1" plugin="$2"
  local script="$sbx/check.sh"
  patch_installer "$plugin" "$script"
  # PATH is sandbox-only: we symlinked the real system tools we need into
  # $sbx/bin (see _provision_real_tools). brew/npm/curl/tar can only resolve
  # if a test explicitly installs a mock for them.
  local path="$sbx/bin:$sbx/home/.local/bin"
  env -i \
    PATH="$path" \
    HOME="$sbx/home" \
    TMPDIR="$sbx/tmp" \
    TMP_DIR="$TMP_DIR" \
    bash "$script"
}

# ----- binary already on PATH: no-op, zero install calls -----

_test_binary_present_noop() {
  local plugin="$1"
  local binary; binary=$(_meta_binary "$plugin")
  local sbx; sbx=$(new_sandbox "noop-$plugin")
  local log="$sbx/install.log"
  : > "$log"
  # Pre-install fake binary on PATH.
  printf '#!/usr/bin/env bash\nexit 0\n' > "$sbx/bin/$binary"
  chmod +x "$sbx/bin/$binary"
  # No install mocks present.
  if ! _run_installer "$sbx" "$plugin" >"$sbx/out.log" 2>&1; then
    echo "exit non-zero with binary present:"; cat "$sbx/out.log"; return 1
  fi
  if [[ -s "$log" ]]; then
    echo "expected zero install calls, got:"; cat "$log"; return 1
  fi
}

# ----- primary install method present, binary absent: exactly one install call -----

_test_primary_install_brew() {
  local plugin="$1" formula="$2" target="$3"
  local sbx; sbx=$(new_sandbox "brew-$plugin")
  local log="$sbx/install.log"
  : > "$log"
  make_install_mock "$sbx/bin" brew "$log" "$target"
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
  # Force the npm branch by having only npm available (no brew).
  local sbx; sbx=$(new_sandbox "npm-$plugin")
  local log="$sbx/install.log"
  : > "$log"
  make_install_mock "$sbx/bin" npm "$log" "$target"
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
  # No brew on PATH -> falls back to curl | tar xz.
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
  # The pipeline must be exactly one install attempt: one curl call and one tar call.
  local curl_calls tar_calls
  curl_calls=$(grep -c '^curl ' "$log")
  tar_calls=$(grep -c '^tar ' "$log")
  if (( curl_calls != 1 || tar_calls != 1 )); then
    echo "expected 1 curl + 1 tar, got curl=$curl_calls tar=$tar_calls"
    cat "$log"
    return 1
  fi
  # tar invocation must include the 'xz' flag pair (extract + gunzip).
  # Match `xz` as its own argument: surrounded by start/space and space/end.
  if ! grep -E '^tar( .*)? xz( |$)' "$log" >/dev/null; then
    echo "tar call missing 'xz' flag:"; cat "$log"; return 1
  fi
}

_test_regal_binary_install() {
  # Linux path: regal always uses binary download (no brew branch on non-Darwin).
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
  # Curl call must write to $HOME/.local/bin/regal. grep -F so $sbx isn't
  # interpreted as a regex.
  if ! grep -F -- "-o $sbx/home/.local/bin/regal" "$log" >/dev/null; then
    echo "curl call did not target the expected install path:"; cat "$log"; return 1
  fi
}

# ----- all install methods absent: exit non-zero with stderr message -----

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
  # Stderr or stdout should mention the missing tooling.
  if ! grep -iE 'Neither Homebrew nor npm|Install one of them' "$sbx/out.log" "$sbx/err.log" >/dev/null; then
    echo "expected 'Neither Homebrew nor npm' message; got:"
    echo "--- stdout ---"; cat "$sbx/out.log"
    echo "--- stderr ---"; cat "$sbx/err.log"
    return 1
  fi
}

# ----- registration: explicit wrappers per scenario for clear failure names -----

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
