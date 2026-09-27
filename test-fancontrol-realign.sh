#!/usr/bin/env bash
#
# test-fancontrol-realign.sh — self-test for fancontrol-realign.sh.
# Builds a fake /sys/class/hwmon tree in a temp dir (hwmon numbers chosen
# to differ from the sample /etc/fancontrol) and checks the rewritten config.
#
# Usage: test-fancontrol-realign.sh [path-to-sample-fancontrol]

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
SAMPLE="${1:-$SCRIPT_DIR/fancontrol}"
SCRIPT="$SCRIPT_DIR/fancontrol-realign.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

HWMON="$WORK/hwmon"
DEVS="$WORK/devices"

mkdir -p "$HWMON"

# make_device <dir> <driver-name>
make_device() {
    mkdir -p "$1"
    printf '%s\n' "$2" > "$1/name"
}

# link <hwmonN> <target relative to $HWMON>
link() {
    ln -s "$2" "$HWMON/$1"
}

pass=0
fail=0
check() { # check <desc> <expected-in-config>
    local desc="$1" needle="$2"
    if grep -qF -- "$needle" "$WORK/conf"; then
        echo "  ok: $desc"
        pass=$((pass+1))
    else
        echo "  FAIL: $desc (missing: $needle)"
        fail=$((fail+1))
    fi
}

check_absent() { # check_absent <desc> <string-not-in-config>
    local desc="$1" needle="$2"
    if grep -qF -- "$needle" "$WORK/conf"; then
        echo "  FAIL: $desc (found: $needle)"
        fail=$((fail+1))
    else
        echo "  ok: $desc"
        pass=$((pass+1))
    fi
}

# device paths as used in /etc/fancontrol (relative to /sys)
AMD_PATH="devices/pci0000:00/0000:00:03.1/0000:07:00.0/0000:08:00.0/0000:09:00.0"
IT_PATH="devices/platform/it87.2624"
# same paths relative to $DEVS (for building the fixture tree)
AMD_REL="pci0000:00/0000:00:03.1/0000:07:00.0/0000:08:00.0/0000:09:00.0"
IT_REL="platform/it87.2624"

# distractor devices that must be ignored
add_distractors() {
    make_device "$DEVS/virtual/thermal/thermal_zone0/hwmon0" "acpitz"
    link hwmon0 "../devices/virtual/thermal/thermal_zone0/hwmon0"
    make_device "$DEVS/pci0000:00/0000:00:01.1/0000:01:00.0/nvme/nvme0/hwmon9" "nvme"
    link hwmon9 "../devices/pci0000:00/0000:00:01.1/0000:01:00.0/nvme/nvme0/hwmon9"
}

run_case() { # run_case <name> <amd-hwmonN> <it-hwmonN>
    local name="$1" n_amd="$2" n_it="$3"
    echo "== case: $name (amdgpu=hwmon$n_amd, it87=hwmon$n_it)"
    rm -rf "$HWMON" "$DEVS"
    mkdir -p "$HWMON"
    make_device "$DEVS/$AMD_REL/hwmon/hwmon$n_amd" "amdgpu"
    make_device "$DEVS/$IT_REL/hwmon/hwmon$n_it" "it8622"
    link "hwmon$n_amd" "../devices/$AMD_REL/hwmon/hwmon$n_amd"
    link "hwmon$n_it" "../devices/$IT_REL/hwmon/hwmon$n_it"
    add_distractors

    cp "$SAMPLE" "$WORK/conf"
    FANCONTROL_CONF="$WORK/conf" FANCONTROL_HWMON_DIR="$HWMON" \
        FANCONTROL_MAX_WAIT=5 "$SCRIPT" --no-start
}

# ---------------------------------------------------------------- case 1
# numbers shifted down: hwmon3->hwmon1, hwmon4->hwmon2
run_case "shifted" 1 2
check "amdgpu DEVPATH rekeyed" "DEVPATH=hwmon1=$AMD_PATH hwmon2=$IT_PATH"
check "DEVNAME rekeyed" "DEVNAME=hwmon1=amdgpu hwmon2=it8622"
check "FCTEMPS rekeyed" "FCTEMPS=hwmon2/pwm3=hwmon1/temp1_input hwmon2/pwm2=hwmon1/temp1_input"
check "FCFANS rekeyed" "FCFANS=hwmon2/pwm3=hwmon2/fan3_input hwmon2/pwm2=hwmon2/fan2_input"
check "MINTEMP rekeyed" "MINTEMP=hwmon2/pwm3=20 hwmon2/pwm2=20"
check "MAXTEMP rekeyed" "MAXTEMP=hwmon2/pwm3=60 hwmon2/pwm2=60"
check "MINSTART rekeyed" "MINSTART=hwmon2/pwm3=150 hwmon2/pwm2=150"
check "MINSTOP rekeyed" "MINSTOP=hwmon2/pwm3=0 hwmon2/pwm2=0"
check "MINPWM rekeyed" "MINPWM=hwmon2/pwm3=0 hwmon2/pwm2=0"
check "MAXPWM rekeyed" "MAXPWM=hwmon2/pwm3=255 hwmon2/pwm2=255"
check_absent "old hwmon3 gone" "hwmon3"
check_absent "old hwmon4 gone" "hwmon4"
check "INTERVAL preserved" "INTERVAL=10"
grep -qF "DEVPATH=hwmon3=$AMD_PATH hwmon4=$IT_PATH" "$WORK/conf.bak" \
    && { echo "  ok: backup holds pre-realign config"; pass=$((pass+1)); } \
    || { echo "  FAIL: backup does not hold pre-realign config"; fail=$((fail+1)); }

# ---------------------------------------------------------------- case 2
# swapped numbers: hwmon3<->hwmon4 (tests the two-phase placeholder rewrite)
run_case "swapped" 4 3
check "swapped: DEVPATH rekeyed" "DEVPATH=hwmon4=$AMD_PATH hwmon3=$IT_PATH"
check "swapped: DEVNAME rekeyed" "DEVNAME=hwmon4=amdgpu hwmon3=it8622"
check "swapped: FCTEMPS rekeyed" "FCTEMPS=hwmon3/pwm3=hwmon4/temp1_input hwmon3/pwm2=hwmon4/temp1_input"
check_absent "swapped: no clobbering" "hwmon4/pwm3=hwmon4/temp1_input"

# ---------------------------------------------------------------- case 3
# already aligned: no rewrite, no backup created
rm -f "$WORK/conf.bak"
run_case "aligned" 3 4
check "aligned: unchanged DEVPATH" "DEVPATH=hwmon3=$AMD_PATH hwmon4=$IT_PATH"
if [[ -f $WORK/conf.bak ]]; then
    echo "  FAIL: aligned case should not create a backup"; fail=$((fail+1))
else
    echo "  ok: aligned case created no backup"; pass=$((pass+1))
fi

# ---------------------------------------------------------------- case 4
# target devices missing: must time out with non-zero exit, config untouched
rm -rf "$HWMON" "$DEVS"
mkdir -p "$HWMON"
add_distractors
cp "$SAMPLE" "$WORK/conf"
if FANCONTROL_CONF="$WORK/conf" FANCONTROL_HWMON_DIR="$HWMON" \
    FANCONTROL_MAX_WAIT=2 "$SCRIPT" --no-start 2>/dev/null; then
    echo "  FAIL: missing device should time out non-zero"; fail=$((fail+1))
else
    echo "  ok: missing device timed out with non-zero exit"; pass=$((pass+1))
fi
check "timeout: config untouched" "DEVPATH=hwmon3=$AMD_PATH hwmon4=$IT_PATH"

echo
echo "result: $pass passed, $fail failed"
[[ $fail -eq 0 ]]
