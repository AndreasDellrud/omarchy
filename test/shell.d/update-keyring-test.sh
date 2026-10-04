#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT

stub_bin="$test_tmp/bin"
log_file="$test_tmp/keyring.log"
mkdir -p "$stub_bin"

# Behavior is driven by env vars so each case can pick its failure point:
# KEYRING_TEST_PKG_MISSING     exit status of omarchy-pkg-missing (default 1: installed)
# KEYRING_TEST_LIST_FAIL_ON    which --list-keys call fails, counted per run (default: none)
# KEYRING_TEST_RECV_STATUS     exit status of --recv-keys (default 0)
# KEYRING_TEST_REINSTALL_STATUS exit status of the archlinux-keyring reinstall (default 0)
# KEYRING_TEST_ARCH            what uname -m reports (default x86_64)
# KEYRING_TEST_ALARM_TRUST     starting validity of the Arch Linux ARM key: f (trusted),
#                              - (imported by pacman's prompt, untrusted) or empty (absent)
# KEYRING_TEST_ALARM_PKG_PRESENT exit status of omarchy-pkg-present archlinuxarm-keyring (default 0)
# KEYRING_TEST_ALARM_FIX       validity populate/lsign leave behind (default f)
# KEYRING_TEST_ALARM_RECV_STATUS exit status of the Arch Linux ARM key recv (default 0)
alarm_key=68B3537F39A313B3E574D06777193F152BDBE6A6

cat >"$stub_bin/sudo" <<'SH'
#!/bin/bash

printf 'sudo' >>"$KEYRING_TEST_LOG"
for arg in "$@"; do
  printf '\t%s' "$arg" >>"$KEYRING_TEST_LOG"
done
printf '\n' >>"$KEYRING_TEST_LOG"

alarm_key=68B3537F39A313B3E574D06777193F152BDBE6A6
trust_file="$KEYRING_TEST_DIR/alarm-trust"

if [[ $1 == "gpg" && ${*: -1} == "$alarm_key" ]]; then
  trust=$(cat "$trust_file" 2>/dev/null)
  [[ -n $trust ]] || exit 2
  printf 'tru::1:0:0:3:1:5\npub:%s:4096:1:77193F152BDBE6A6:1390085363:::-:::scESC::::::23::0:\n' "$trust"
  exit 0
fi

if [[ $1 == "pacman-key" && $2 == "--populate" && $3 == "archlinuxarm" ]]; then
  echo "${KEYRING_TEST_ALARM_FIX:-f}" >"$trust_file"
  exit 0
fi

if [[ $1 == "pacman-key" && $2 == "--recv-keys" && $3 == "$alarm_key" ]]; then
  status=${KEYRING_TEST_ALARM_RECV_STATUS:-0}
  (( status != 0 )) || echo - >"$trust_file"
  exit "$status"
fi

if [[ $1 == "pacman-key" && $2 == "--lsign-key" && $3 == "$alarm_key" ]]; then
  echo "${KEYRING_TEST_ALARM_FIX:-f}" >"$trust_file"
  exit 0
fi

if [[ $1 == "pacman" && $* == *archlinuxarm-keyring* ]]; then
  # The package's install script populates the keys it ships, which only
  # trusts the key if populating does.
  [[ $(cat "$trust_file" 2>/dev/null) == "f" ]] || echo "${KEYRING_TEST_ALARM_FIX:-f}" >"$trust_file"
  exit 0
fi

if [[ $1 == "pacman-key" && $2 == "--list-keys" ]]; then
  calls_file="$KEYRING_TEST_DIR/list-calls"
  calls=$(( $(cat "$calls_file" 2>/dev/null || echo 0) + 1 ))
  echo "$calls" >"$calls_file"
  if [[ ${KEYRING_TEST_LIST_FAIL_ON:-} == "$calls" ]]; then
    exit 1
  fi
  exit 0
fi

if [[ $1 == "pacman-key" && $2 == "--recv-keys" ]]; then
  exit "${KEYRING_TEST_RECV_STATUS:-0}"
fi

if [[ $1 == "pacman-key" && $2 == "--lsign-key" ]]; then
  exit 0
fi

if [[ $1 == "pacman" && $* == *archlinux-keyring* ]]; then
  exit "${KEYRING_TEST_REINSTALL_STATUS:-0}"
fi

exit 0
SH
chmod +x "$stub_bin/sudo"

cat >"$stub_bin/omarchy-pkg-missing" <<'SH'
#!/bin/bash

exit "${KEYRING_TEST_PKG_MISSING:-1}"
SH
chmod +x "$stub_bin/omarchy-pkg-missing"

cat >"$stub_bin/omarchy-pkg-add" <<'SH'
#!/bin/bash

printf 'pkg-add\t%s\n' "$1" >>"$KEYRING_TEST_LOG"
exit 0
SH
chmod +x "$stub_bin/omarchy-pkg-add"

cat >"$stub_bin/omarchy-pkg-present" <<'SH'
#!/bin/bash

[[ $1 == "archlinuxarm-keyring" ]] || exit 1
exit "${KEYRING_TEST_ALARM_PKG_PRESENT:-0}"
SH
chmod +x "$stub_bin/omarchy-pkg-present"

cat >"$stub_bin/uname" <<'SH'
#!/bin/bash

[[ $1 == "-m" ]] && echo "${KEYRING_TEST_ARCH:-x86_64}"
SH
chmod +x "$stub_bin/uname"

run_keyring() {
  printf '%s\n' "${KEYRING_TEST_ALARM_TRUST-f}" >"$test_tmp/alarm-trust"
  KEYRING_TEST_LOG="$log_file" \
    KEYRING_TEST_DIR="$test_tmp" \
    PATH="$stub_bin:$PATH" \
    "$ROOT/bin/omarchy-update-keyring" "$@"
}

# Everything healthy: the key and package are present, the reinstall works.
: >"$log_file"
rm -f "$test_tmp/list-calls"
run_keyring >"$test_tmp/ok.out"

grep -F "Keys are correct" "$test_tmp/ok.out" >/dev/null ||
  fail "update-keyring reports success when the keyring is healthy" "$(cat "$test_tmp/ok.out")"
pass "update-keyring reports success when the keyring is healthy"

grep -Eq $'^sudo\tpacman\t-Sy\t--noconfirm\tarchlinux-keyring$' "$log_file" ||
  fail "update-keyring still reinstalls archlinux-keyring" "$(cat "$log_file")"
pass "update-keyring still reinstalls archlinux-keyring"

# Key and package missing: the full populate path runs and verifies at the end.
: >"$log_file"
rm -f "$test_tmp/list-calls"
KEYRING_TEST_PKG_MISSING=0 run_keyring >"$test_tmp/populate.out"

grep -F "Keys are correct" "$test_tmp/populate.out" >/dev/null ||
  fail "update-keyring populates a missing keyring and reports success" "$(cat "$test_tmp/populate.out")"
for expected in 'recv-keys' 'lsign-key' $'pkg-add\tomarchy-keyring'; do
  grep -Eq "$expected" "$log_file" ||
    fail "update-keyring populates a missing keyring and reports success" "$(cat "$log_file")"
done
pass "update-keyring populates a missing keyring and reports success"

# recv-keys failing must stop the script, not end in "Keys are correct".
: >"$log_file"
rm -f "$test_tmp/list-calls"
if KEYRING_TEST_PKG_MISSING=0 KEYRING_TEST_RECV_STATUS=1 run_keyring >"$test_tmp/recv.out" 2>&1; then
  fail "update-keyring fails when recv-keys fails"
fi
if grep -F "Keys are correct" "$test_tmp/recv.out" >/dev/null; then
  fail "update-keyring fails when recv-keys fails" "$(cat "$test_tmp/recv.out")"
fi
if grep -q 'lsign-key' "$log_file"; then
  fail "update-keyring stops at the failed recv instead of signing anyway" "$(cat "$log_file")"
fi
pass "update-keyring fails when recv-keys fails"

# A failed archlinux-keyring reinstall must not end in success either.
: >"$log_file"
rm -f "$test_tmp/list-calls"
if KEYRING_TEST_REINSTALL_STATUS=1 run_keyring >"$test_tmp/reinstall.out" 2>&1; then
  fail "update-keyring fails when the archlinux-keyring reinstall fails"
fi
if grep -F "Keys are correct" "$test_tmp/reinstall.out" >/dev/null; then
  fail "update-keyring fails when the archlinux-keyring reinstall fails" "$(cat "$test_tmp/reinstall.out")"
fi
pass "update-keyring fails when the archlinux-keyring reinstall fails"

# The closing check is what backs the success line: the first --list-keys
# passes (key present, populate skipped), the verifying one fails.
: >"$log_file"
rm -f "$test_tmp/list-calls"
if KEYRING_TEST_LIST_FAIL_ON=2 run_keyring >"$test_tmp/verify.out" 2>&1; then
  fail "update-keyring fails when the final key check fails"
fi
if grep -F "Keys are correct" "$test_tmp/verify.out" >/dev/null; then
  fail "update-keyring fails when the final key check fails" "$(cat "$test_tmp/verify.out")"
fi
pass "update-keyring fails when the final key check fails"

# x86_64 never touches Arch Linux ARM's keyring.
: >"$log_file"
rm -f "$test_tmp/list-calls"
run_keyring >"$test_tmp/x86.out"
if grep -Eq 'archlinuxarm|gpg' "$log_file"; then
  fail "update-keyring leaves Arch Linux ARM's keyring alone on x86_64" "$(cat "$log_file")"
fi
pass "update-keyring leaves Arch Linux ARM's keyring alone on x86_64"

# aarch64, healthy: the Arch Linux ARM keyring is reinstalled before
# archlinux-keyring, which Arch Linux ARM signs with that keyring's key.
: >"$log_file"
rm -f "$test_tmp/list-calls"
KEYRING_TEST_ARCH=aarch64 run_keyring >"$test_tmp/arm-ok.out"
grep -F "Keys are correct" "$test_tmp/arm-ok.out" >/dev/null ||
  fail "update-keyring refreshes Arch Linux ARM's keyring first on aarch64" "$(cat "$test_tmp/arm-ok.out")"
alarm_line=$(grep -nE $'^sudo\tpacman\t-Sy\t--noconfirm\tarchlinuxarm-keyring$' "$log_file" | cut -d: -f1 || true)
arch_line=$(grep -nE $'^sudo\tpacman\t-Sy\t--noconfirm\tarchlinux-keyring$' "$log_file" | cut -d: -f1 || true)
[[ -n $alarm_line && -n $arch_line ]] && (( alarm_line < arch_line )) ||
  fail "update-keyring refreshes Arch Linux ARM's keyring first on aarch64" "$(cat "$log_file")"
if grep -Eq $'pacman-key\t--(populate|recv-keys|lsign-key)\t(archlinuxarm|'"$alarm_key"')' "$log_file"; then
  fail "update-keyring does not re-bootstrap a trusted Arch Linux ARM key" "$(cat "$log_file")"
fi
pass "update-keyring refreshes Arch Linux ARM's keyring first on aarch64"

# aarch64, package installed but never populated: populate it from the package.
: >"$log_file"
rm -f "$test_tmp/list-calls"
KEYRING_TEST_ARCH=aarch64 KEYRING_TEST_ALARM_TRUST= run_keyring >"$test_tmp/arm-populate.out"
grep -F "Keys are correct" "$test_tmp/arm-populate.out" >/dev/null ||
  fail "update-keyring populates an installed Arch Linux ARM keyring" "$(cat "$test_tmp/arm-populate.out")"
grep -Eq $'^sudo\tpacman-key\t--populate\tarchlinuxarm$' "$log_file" ||
  fail "update-keyring populates an installed Arch Linux ARM keyring" "$(cat "$log_file")"
pass "update-keyring populates an installed Arch Linux ARM keyring"

# aarch64, package missing and the key only imported by pacman's prompt (the
# first T7 install): fetch it by fingerprint, sign it, then install the package.
: >"$log_file"
rm -f "$test_tmp/list-calls"
KEYRING_TEST_ARCH=aarch64 KEYRING_TEST_ALARM_TRUST=- KEYRING_TEST_ALARM_PKG_PRESENT=1 run_keyring >"$test_tmp/arm-recv.out"
grep -F "Keys are correct" "$test_tmp/arm-recv.out" >/dev/null ||
  fail "update-keyring bootstraps a missing Arch Linux ARM keyring" "$(cat "$test_tmp/arm-recv.out")"
for expected in $'^sudo\tpacman-key\t--recv-keys\t'"$alarm_key"$'\t--keyserver\tkeyserver.ubuntu.com$' \
  $'^sudo\tpacman-key\t--lsign-key\t'"$alarm_key"'$' \
  $'^sudo\tpacman\t-Sy\t--noconfirm\tarchlinuxarm-keyring$'; do
  grep -Eq "$expected" "$log_file" ||
    fail "update-keyring bootstraps a missing Arch Linux ARM keyring" "$(cat "$log_file")"
done
pass "update-keyring bootstraps a missing Arch Linux ARM keyring"

# A failed recv stops before signing anything or touching archlinux-keyring.
: >"$log_file"
rm -f "$test_tmp/list-calls"
if KEYRING_TEST_ARCH=aarch64 KEYRING_TEST_ALARM_TRUST= KEYRING_TEST_ALARM_PKG_PRESENT=1 KEYRING_TEST_ALARM_RECV_STATUS=1 \
  run_keyring >"$test_tmp/arm-recv-fail.out" 2>&1; then
  fail "update-keyring fails when the Arch Linux ARM key cannot be fetched"
fi
if grep -Eq $'lsign-key\t'"$alarm_key"$'|archlinux-keyring$' "$log_file"; then
  fail "update-keyring fails when the Arch Linux ARM key cannot be fetched" "$(cat "$log_file")"
fi
pass "update-keyring fails when the Arch Linux ARM key cannot be fetched"

# A key that is present but still not trusted at the end must not pass: that
# is the state pacman reports as "unknown trust".
: >"$log_file"
rm -f "$test_tmp/list-calls"
if KEYRING_TEST_ARCH=aarch64 KEYRING_TEST_ALARM_TRUST=- KEYRING_TEST_ALARM_FIX=- run_keyring >"$test_tmp/arm-untrusted.out" 2>&1; then
  fail "update-keyring fails while the Arch Linux ARM key is untrusted"
fi
if grep -F "Keys are correct" "$test_tmp/arm-untrusted.out" >/dev/null; then
  fail "update-keyring fails while the Arch Linux ARM key is untrusted" "$(cat "$test_tmp/arm-untrusted.out")"
fi
pass "update-keyring fails while the Arch Linux ARM key is untrusted"
