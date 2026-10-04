#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
devices="$test_tmp/devices"
log_file="$test_tmp/calls.log"
uuid=b8f58780-002a-50c4-ffff-ffffffffffff
mkdir -p "$stub_bin"

# Behavior is driven by env vars so each case picks the state it needs:
# ENROLL_TEST_LOCKED   exit status of omarchy-hyprland-session-locked (default 1: unlocked)
# ENROLL_TEST_ACTIVE   the session's Active property (default yes)
# ENROLL_TEST_REMOTE   the session's Remote property (default no)
# ENROLL_TEST_STORED   what boltctl info reports as stored (default no)
cat >"$stub_bin/omarchy-hyprland-session-locked" <<'SH'
#!/bin/bash

exit "${ENROLL_TEST_LOCKED:-1}"
SH

cat >"$stub_bin/loginctl" <<'SH'
#!/bin/bash

case "$*" in
  *"-p Active"*) echo "${ENROLL_TEST_ACTIVE:-yes}" ;;
  *"-p Remote"*) echo "${ENROLL_TEST_REMOTE:-no}" ;;
esac
SH

cat >"$stub_bin/boltctl" <<'SH'
#!/bin/bash

printf 'boltctl %s\n' "$*" >>"$ENROLL_TEST_LOG"
if [[ $1 == "info" ]]; then
  printf ' * CalDigit, Inc. TS4\n   |- status:        connected\n   `- stored:        %s\n' "${ENROLL_TEST_STORED:-no}"
fi
SH

cat >"$stub_bin/omarchy-notification-send" <<'SH'
#!/bin/bash

printf 'notify %s\n' "$*" >>"$ENROLL_TEST_LOG"
SH

chmod +x "$stub_bin"/*

make_device() {
  local authorized=$1
  rm -rf "$devices"
  mkdir -p "$devices/0-1"
  echo "$uuid" >"$devices/0-1/unique_id"
  echo "$authorized" >"$devices/0-1/authorized"
  echo "CalDigit, Inc." >"$devices/0-1/vendor_name"
  echo "TS4" >"$devices/0-1/device_name"
}

run_enroll() {
  : >"$log_file"
  ENROLL_TEST_LOG="$log_file" \
    OMARCHY_THUNDERBOLT_DEVICES_PATH="$devices" \
    XDG_SESSION_ID="${XDG_SESSION_ID-1}" \
    PATH="$stub_bin:$PATH" \
    "$ROOT/bin/omarchy-hw-thunderbolt-enroll" "${1:-0-1}" >"$test_tmp/out" 2>&1
}

enrolled() {
  grep -qx "boltctl enroll --policy auto $uuid" "$log_file"
}

make_device 0
run_enroll
enrolled || fail "a new device plugged in while unlocked is enrolled" "$(cat "$log_file")"
grep -q '^notify .*Approved CalDigit, Inc. TS4' "$log_file" ||
  fail "a new device plugged in while unlocked is enrolled" "$(cat "$log_file")"
pass "a new device plugged in while unlocked is enrolled"

for locked in 0 2; do
  make_device 0
  ENROLL_TEST_LOCKED=$locked run_enroll
  if enrolled || grep -q '^boltctl' "$log_file"; then
    fail "nothing is enrolled while the lock state is $locked" "$(cat "$log_file")"
  fi
done
grep -q 'plug it in again after unlocking' "$test_tmp/out" ||
  fail "nothing is enrolled while locked or the lock state is unknown" "$(cat "$test_tmp/out")"
pass "nothing is enrolled while locked or the lock state is unknown"

make_device 0
ENROLL_TEST_ACTIVE=no run_enroll
enrolled && fail "nothing is enrolled for an inactive session" "$(cat "$log_file")"
ENROLL_TEST_REMOTE=yes run_enroll
enrolled && fail "nothing is enrolled for a remote session" "$(cat "$log_file")"
XDG_SESSION_ID= run_enroll
enrolled && fail "nothing is enrolled without a session" "$(cat "$log_file")"
pass "only the active local session enrolls"

make_device 0
ENROLL_TEST_STORED="Sun 04 Oct 2026 03:26:11 PM UTC" run_enroll
enrolled && fail "a device boltd already stores is left to boltd" "$(cat "$log_file")"
pass "a device boltd already stores is left to boltd"

make_device 1
run_enroll
enrolled && fail "an authorized device is left alone" "$(cat "$log_file")"
pass "an authorized device is left alone"

make_device 0
run_enroll 0-9
[[ ! -s $log_file ]] || fail "a device that is already gone is ignored" "$(cat "$log_file")"
pass "a device that is already gone is ignored"

rule="$ROOT/etc/udev/rules.d/70-omarchy-thunderbolt-enroll.rules"
grep -q 'ATTR{authorized}=="0"' "$rule" &&
  grep -q 'ENV{SYSTEMD_USER_WANTS}+="omarchy-thunderbolt-enroll@%k.service"' "$rule" ||
  fail "the udev rule asks user managers to enroll unauthorized devices" "$(cat "$rule")"
grep -qx 'ExecStart=/usr/bin/omarchy-hw-thunderbolt-enroll %i' "$ROOT/default/systemd/user/omarchy-thunderbolt-enroll@.service" ||
  fail "the udev rule asks user managers to enroll unauthorized devices"
if command -v udevadm >/dev/null && udevadm verify --help >/dev/null 2>&1; then
  udevadm verify --no-style "$rule" >/dev/null || fail "the udev rule asks user managers to enroll unauthorized devices" "$(udevadm verify "$rule" 2>&1)"
fi
pass "the udev rule asks user managers to enroll unauthorized devices"
