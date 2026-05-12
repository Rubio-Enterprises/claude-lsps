# shellcheck source=../helpers/mock-bin.sh
source "$TESTS_DIR/helpers/mock-bin.sh"

# Slow install mock with a built-in sleep, used to force the two parallel
# invocations to overlap and contend on the lock.
_make_slow_install_mock() {
  local bin_dir="$1" name="$2" log="$3" target="$4"
  cat >"$bin_dir/$name" <<EOF
#!/usr/bin/env bash
# Append is atomic for small writes with O_APPEND.
printf '%s %s\n' "$name" "\$*" >> "$log"
sleep 0.1
tmpf=\$(mktemp "$bin_dir/.tmp.XXXXXX")
printf '#!/usr/bin/env bash\nexit 0\n' > "\$tmpf"
chmod +x "\$tmpf"
mv "\$tmpf" "$bin_dir/$target"
EOF
  chmod +x "$bin_dir/$name"
}

_make_slow_curl_mock() {
  local bin_dir="$1" log="$2"
  cat >"$bin_dir/curl" <<EOF
#!/usr/bin/env bash
printf 'curl %s\n' "\$*" >> "$log"
sleep 0.1
out=""
args=( "\$@" )
i=0
while (( i < \${#args[@]} )); do
  case "\${args[\$i]}" in
    -o) out="\${args[\$((i+1))]}"; i=\$((i+2)) ;;
    *) i=\$((i+1)) ;;
  esac
done
if [[ -n "\$out" ]]; then
  mkdir -p "\$(dirname "\$out")"
  printf '#!/usr/bin/env bash\nexit 0\n' > "\$out"
  chmod +x "\$out"
else
  printf 'X'
fi
EOF
  chmod +x "$bin_dir/curl"
}

_run_two() {
  local sbx="$1" plugin="$2"
  local script="$sbx/check.sh"
  patch_installer "$plugin" "$script"
  local path="$sbx/bin:$sbx/home/.local/bin"
  local p1 p2
  env -i PATH="$path" HOME="$sbx/home" TMPDIR="$sbx/tmp" bash "$script" \
      >"$sbx/out1.log" 2>"$sbx/err1.log" &
  p1=$!
  env -i PATH="$path" HOME="$sbx/home" TMPDIR="$sbx/tmp" bash "$script" \
      >"$sbx/out2.log" 2>"$sbx/err2.log" &
  p2=$!
  local rc1=0 rc2=0
  wait $p1 || rc1=$?
  wait $p2 || rc2=$?
  if (( rc1 != 0 || rc2 != 0 )); then
    echo "concurrent runs exited non-zero: rc1=$rc1 rc2=$rc2"
    echo "--- out1 ---"; cat "$sbx/out1.log" "$sbx/err1.log"
    echo "--- out2 ---"; cat "$sbx/out2.log" "$sbx/err2.log"
    return 1
  fi
}

_test_concurrency_brew() {
  local plugin="$1" target="$2"
  local sbx; sbx=$(new_sandbox "conc-brew-$plugin")
  local log="$sbx/install.log"
  : > "$log"
  _make_slow_install_mock "$sbx/bin" brew "$log" "$target"
  if ! _run_two "$sbx" "$plugin"; then return 1; fi
  local calls; calls=$(wc -l <"$log")
  if (( calls != 1 )); then
    echo "expected exactly 1 install call across two runs, got $calls"
    cat "$log"
    return 1
  fi
}

_test_concurrency_curl() {
  local plugin="$1"
  local sbx; sbx=$(new_sandbox "conc-curl-$plugin")
  local log="$sbx/install.log"
  : > "$log"
  _make_slow_curl_mock "$sbx/bin" "$log"
  if ! _run_two "$sbx" "$plugin"; then return 1; fi
  local calls; calls=$(grep -c '^curl ' "$log" || true)
  if (( calls != 1 )); then
    echo "expected exactly 1 curl install call across two runs, got $calls"
    cat "$log"
    return 1
  fi
}

tc_conc_ansible() { _test_concurrency_brew ansible-language-server ansible-language-server; }
tc_conc_bash()    { _test_concurrency_brew bash-language-server bash-language-server; }
tc_conc_cue()     { _test_concurrency_brew cue-lsp cue; }
tc_conc_pyright() { _test_concurrency_brew pyright pyright-langserver; }
tc_conc_vtsls()   { _test_concurrency_brew vtsls vtsls; }
tc_conc_regal()   { _test_concurrency_curl regal-lsp; }

register_test "installer/concurrency-ansible" tc_conc_ansible
register_test "installer/concurrency-bash"    tc_conc_bash
register_test "installer/concurrency-cue"     tc_conc_cue
register_test "installer/concurrency-pyright" tc_conc_pyright
register_test "installer/concurrency-vtsls"   tc_conc_vtsls
register_test "installer/concurrency-regal"   tc_conc_regal
