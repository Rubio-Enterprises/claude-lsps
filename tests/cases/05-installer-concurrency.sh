# shellcheck shell=bash
# shellcheck source=../helpers/mock-bin.sh
source "$TESTS_DIR/helpers/mock-bin.sh"

# Slow install mock with a built-in sleep, used to force the two parallel
# invocations to overlap and contend on the lock. Records start+end timestamps
# (epoch nanoseconds via $EPOCHREALTIME) per call so we can prove that the
# second invocation either skipped install entirely (lock acquired after first
# completed and the binary check at the top of the critical section short-
# circuited) or actually waited.
_make_slow_install_mock() {
  local bin_dir="$1" name="$2" log="$3" target="$4" timing="$5"
  cat >"$bin_dir/$name" <<EOF
#!/usr/bin/env bash
# Append is atomic for small writes with O_APPEND.
printf '%s\tstart\t%s\n' "$name" "\${EPOCHREALTIME:-\$(date +%s.%N)}" >> "$timing"
printf '%s %s\n' "$name" "\$*" >> "$log"
sleep 0.3
tmpf=\$(mktemp "$bin_dir/.tmp.XXXXXX")
printf '#!/usr/bin/env bash\nexit 0\n' > "\$tmpf"
chmod +x "\$tmpf"
mv "\$tmpf" "$bin_dir/$target"
printf '%s\tend\t%s\n' "$name" "\${EPOCHREALTIME:-\$(date +%s.%N)}" >> "$timing"
EOF
  chmod +x "$bin_dir/$name"
}

_make_slow_curl_mock() {
  local bin_dir="$1" log="$2" timing="$3"
  cat >"$bin_dir/curl" <<EOF
#!/usr/bin/env bash
printf 'curl\tstart\t%s\n' "\${EPOCHREALTIME:-\$(date +%s.%N)}" >> "$timing"
printf 'curl %s\n' "\$*" >> "$log"
sleep 0.3
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
printf 'curl\tend\t%s\n' "\${EPOCHREALTIME:-\$(date +%s.%N)}" >> "$timing"
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
  # PIDs must expand now: by the time the RETURN trap fires, the locals are
  # out of scope. shellcheck disable=SC2064 is intentional here.
  # shellcheck disable=SC2064
  trap "kill $p1 $p2 2>/dev/null; wait $p1 $p2 2>/dev/null" RETURN
  local rc1=0 rc2=0
  wait $p1 || rc1=$?
  wait $p2 || rc2=$?
  if ((rc1 != 0 || rc2 != 0)); then
    echo "concurrent runs exited non-zero: rc1=$rc1 rc2=$rc2"
    echo "--- out1 ---"
    cat "$sbx/out1.log" "$sbx/err1.log"
    echo "--- out2 ---"
    cat "$sbx/out2.log" "$sbx/err2.log"
    return 1
  fi
}

# Returns 0 if the two install events in $timing overlap in wall-clock time,
# proving the lock was *not* serializing the critical section (the test failure
# we want to detect). Returns 1 if they're disjoint (the expected, serialized
# outcome).
_timing_overlapped() {
  local timing="$1" name="$2"
  awk -v name="$name" '
    $1 == name && $2 == "start" { starts[++ns] = $3 + 0 }
    $1 == name && $2 == "end"   { ends[++ne] = $3 + 0 }
    END {
      if (ns < 2 || ne < 2) exit 1
      # Two events overlap iff max(start) < min(end).
      smin = starts[1]; smax = starts[1]; emin = ends[1]; emax = ends[1]
      for (i = 2; i <= ns; i++) { if (starts[i] > smax) smax = starts[i]; if (starts[i] < smin) smin = starts[i] }
      for (i = 2; i <= ne; i++) { if (ends[i]   < emin) emin = ends[i];   if (ends[i]   > emax) emax = ends[i]   }
      exit (smax < emin) ? 0 : 1
    }
  ' "$timing"
}

_test_concurrency_brew() {
  local plugin="$1" target="$2"
  local sbx
  sbx=$(new_sandbox "conc-brew-$plugin")
  local log="$sbx/install.log"
  : >"$log"
  local timing="$sbx/timing.tsv"
  : >"$timing"
  _make_slow_install_mock "$sbx/bin" brew "$log" "$target" "$timing"
  if ! _run_two "$sbx" "$plugin"; then return 1; fi
  local calls
  calls=$(wc -l <"$log")
  if ((calls != 1)); then
    echo "expected exactly 1 install call across two runs, got $calls"
    cat "$log"
    return 1
  fi
  # No second "Installing via Homebrew..." line: that string appears only in
  # do_install, so its absence proves the second process short-circuited at
  # `command -v $BINARY && exit 0` inside the critical section.
  local installing_lines
  installing_lines=$(grep -c 'Installing via Homebrew' "$sbx/out1.log" "$sbx/out2.log" 2>/dev/null | awk -F: 'BEGIN{s=0} {s+=$2} END{print s}')
  if ((installing_lines != 1)); then
    echo "expected exactly one 'Installing via Homebrew' line across both runs; got $installing_lines"
    echo "--- out1 ---"
    cat "$sbx/out1.log"
    echo "--- out2 ---"
    cat "$sbx/out2.log"
    return 1
  fi
}

_test_concurrency_curl() {
  local plugin="$1"
  local sbx
  sbx=$(new_sandbox "conc-curl-$plugin")
  local log="$sbx/install.log"
  : >"$log"
  local timing="$sbx/timing.tsv"
  : >"$timing"
  _make_slow_curl_mock "$sbx/bin" "$log" "$timing"
  if ! _run_two "$sbx" "$plugin"; then return 1; fi
  local calls
  calls=$(grep -c '^curl ' "$log" || true)
  if ((calls != 1)); then
    echo "expected exactly 1 curl install call across two runs, got $calls"
    cat "$log"
    return 1
  fi
  local installing_lines
  installing_lines=$(grep -c 'Installing binary from GitHub' "$sbx/out1.log" "$sbx/out2.log" 2>/dev/null | awk -F: 'BEGIN{s=0} {s+=$2} END{print s}')
  if ((installing_lines != 1)); then
    echo "expected exactly one 'Installing binary from GitHub' line across both runs; got $installing_lines"
    echo "--- out1 ---"
    cat "$sbx/out1.log"
    echo "--- out2 ---"
    cat "$sbx/out2.log"
    return 1
  fi
}

# Variant of _test_concurrency_brew that removes flock from the sandbox so the
# installer takes its mkdir-loop fallback (used on macOS hosts without flock).
# Validates the same serialization property over the alternate locking path.
_test_concurrency_brew_mkdir() {
  local plugin="$1" target="$2"
  local sbx
  sbx=$(new_sandbox "conc-brew-mkdir-$plugin")
  local log="$sbx/install.log"
  : >"$log"
  local timing="$sbx/timing.tsv"
  : >"$timing"
  remove_flock "$sbx/bin"
  _make_slow_install_mock "$sbx/bin" brew "$log" "$target" "$timing"
  if ! _run_two "$sbx" "$plugin"; then return 1; fi
  local calls
  calls=$(wc -l <"$log")
  if ((calls != 1)); then
    echo "expected exactly 1 install call across two runs (mkdir fallback), got $calls"
    cat "$log"
    return 1
  fi
  local installing_lines
  installing_lines=$(grep -c 'Installing via Homebrew' "$sbx/out1.log" "$sbx/out2.log" 2>/dev/null | awk -F: 'BEGIN{s=0} {s+=$2} END{print s}')
  if ((installing_lines != 1)); then
    echo "mkdir-fallback: expected exactly one 'Installing via Homebrew' line; got $installing_lines"
    echo "--- out1 ---"
    cat "$sbx/out1.log"
    echo "--- out2 ---"
    cat "$sbx/out2.log"
    return 1
  fi
  # Lock directory must be cleaned up (the installer registers an EXIT trap).
  if compgen -G "$sbx/lock-*.lock.d" >/dev/null; then
    echo "mkdir lock dir was not cleaned up:"
    compgen -G "$sbx/lock-*.lock.d"
    return 1
  fi
}

tc_conc_ansible() { _test_concurrency_brew ansible-language-server ansible-language-server; }
tc_conc_bash() { _test_concurrency_brew bash-language-server bash-language-server; }
tc_conc_cue() { _test_concurrency_brew cue-lsp cue; }
tc_conc_pyright() { _test_concurrency_brew pyright pyright-langserver; }
tc_conc_vtsls() { _test_concurrency_brew vtsls vtsls; }
tc_conc_regal() { _test_concurrency_curl regal-lsp; }

tc_conc_mkdir_ansible() { _test_concurrency_brew_mkdir ansible-language-server ansible-language-server; }

register_test "installer/concurrency-ansible" tc_conc_ansible
register_test "installer/concurrency-bash" tc_conc_bash
register_test "installer/concurrency-cue" tc_conc_cue
register_test "installer/concurrency-pyright" tc_conc_pyright
register_test "installer/concurrency-vtsls" tc_conc_vtsls
register_test "installer/concurrency-regal" tc_conc_regal

register_test "installer/concurrency-mkdir-ansible" tc_conc_mkdir_ansible
