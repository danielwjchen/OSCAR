#!/usr/bin/env bash
#
# fancontrol-realign.sh — re-align /etc/fancontrol with the hwmon devices
# currently present under /sys/class/hwmon/ after boot.
#
# hwmon numbers (hwmon0..N) are assigned in probe order and can change
# between boots. A /etc/fancontrol that pinned hwmon3=amdgpu /
# hwmon4=it8622 will silently point at the wrong devices after a restart.
# This script:
#
#   1. locates the current hwmonN of the amdgpu temperature sensor and the
#      IT87 fan controller (matched by their stable sysfs device paths,
#      falling back to the driver name in <hwmon>/name),
#   2. rewrites /etc/fancontrol, remapping every reference to those two
#      devices (a rolling backup is kept at /etc/fancontrol.bak),
#   3. (re)starts fancontrol so it picks up the corrected config.
#
# Boot usage (systemd), option A — standalone oneshot unit (recommended):
#
#   [Unit]
#   Description=Re-align /etc/fancontrol with current hwmon devices
#   After=local-fs.target
#   Before=fancontrol.service
#   [Service]
#   Type=oneshot
#   ExecStart=/usr/local/sbin/fancontrol-realign.sh
#   [Install]
#   WantedBy=multi-user.target
#
#   The script starts/restarts the fancontrol service itself (or the
#   fancontrol binary directly if no unit exists).
#
# Option B — hook into an existing fancontrol.service instead:
#
#   ExecStartPre=/usr/local/sbin/fancontrol-realign.sh --no-start
#
#   (--no-start skips service handling because the unit's own ExecStart
#   launches fancontrol.)
#
# Tunables (environment overrides):
#   FANCONTROL_CONF      config file          (default /etc/fancontrol)
#   FANCONTROL_HWMON_DIR hwmon class dir      (default /sys/class/hwmon)
#   FANCONTROL_SERVICE   systemd unit name    (default fancontrol)
#   FANCONTROL_MAX_WAIT  seconds to wait for the hwmon devices to appear

set -euo pipefail

CONF="${FANCONTROL_CONF:-/etc/fancontrol}"
HWMON_DIR="${FANCONTROL_HWMON_DIR:-/sys/class/hwmon}"
SERVICE="${FANCONTROL_SERVICE:-fancontrol}"
MAX_WAIT="${FANCONTROL_MAX_WAIT:-60}"
POLL_DELAY=2
DO_START=1

# ---------------------------------------------------------------------------
# Devices to align: stable sysfs device path (relative to /sys) and a regex
# for the driver name found in <hwmon>/name, used as a fallback match.
# ---------------------------------------------------------------------------
AMDGPU_DEV_PATH="devices/pci0000:00/0000:00:03.1/0000:07:00.0/0000:08:00.0/0000:09:00.0"
AMDGPU_NAME_RE='^amdgpu$'
IT87_DEV_PATH="devices/platform/it87.2624"
IT87_NAME_RE='^it8622$|^it87$'

case "${1:-}" in
    --no-start) DO_START=0 ;;
    -h|--help)
        cat <<'EOF'
usage: fancontrol-realign.sh [--no-start]

Re-aligns /etc/fancontrol with the current /sys/class/hwmon devices and
(start|re)starts fancontrol.

  --no-start   only rewrite the config; do not touch the fancontrol
               service (use this as ExecStartPre= of fancontrol.service)
EOF
        exit 0
        ;;
    *) echo "usage: $0 [--no-start]" >&2; exit 2 ;;
esac

log() { printf '%s [fancontrol-realign] %s\n' "$(date '+%H:%M:%S')" "$*"; }
die() { log "ERROR: $*" >&2; exit 1; }

TMP=""
cleanup() {
    if [[ -n $TMP ]]; then rm -f -- "$TMP"; fi
    return 0
}
trap cleanup EXIT

# Print the hwmonN whose resolved sysfs path contains the given device path.
hwmon_by_path() {
    local want="$1" d resolved
    for d in "$HWMON_DIR"/hwmon*; do
        [[ -e $d ]] || continue
        resolved=$(readlink -f -- "$d") || continue
        case "$resolved" in
            *"$want"/*|*"$want")
                printf '%s\n' "${d##*/}"
                return 0
                ;;
        esac
    done
    return 1
}

# Print the first hwmonN whose <hwmon>/name matches the given ERE.
hwmon_by_name() {
    local re="$1" d name
    for d in "$HWMON_DIR"/hwmon*; do
        [[ -r $d/name ]] || continue
        name=$(<"$d/name") || continue
        if [[ $name =~ $re ]]; then
            printf '%s\n' "${d##*/}"
            return 0
        fi
    done
    return 1
}

# Find a device by path first, then by driver name; prints hwmonN.
find_hwmon() {
    local d
    d=$(hwmon_by_path "$1") && { printf '%s\n' "$d"; return 0; }
    d=$(hwmon_by_name "$2") && { printf '%s\n' "$d"; return 0; }
    return 1
}

# --- 1. Locate current hwmon numbers (retry: drivers may probe late) -------
log "Looking for amdgpu ($AMDGPU_DEV_PATH) and it87 ($IT87_DEV_PATH) in $HWMON_DIR"
new_amd=""
new_it=""
deadline=$((SECONDS + MAX_WAIT))
while :; do
    [[ -n $new_amd ]] || new_amd=$(find_hwmon "$AMDGPU_DEV_PATH" "$AMDGPU_NAME_RE") || true
    [[ -n $new_it ]]  || new_it=$(find_hwmon "$IT87_DEV_PATH" "$IT87_NAME_RE") || true
    [[ -n $new_amd && -n $new_it ]] && break
    if (( SECONDS >= deadline )); then
        die "timed out after ${MAX_WAIT}s; found amdgpu=${new_amd:-<none>} it87=${new_it:-<none>}. Check 'ls -l /sys/class/hwmon' and that the amdgpu/it87 drivers are loaded."
    fi
    sleep "$POLL_DELAY"
done
log "found amdgpu -> $new_amd, it87 -> $new_it"

# --- 2. Determine which hwmonN the current config uses for each device -----
[[ -f $CONF ]] || die "config file $CONF not found"
old_amd=""
old_it=""

# DEVNAME=hwmon3=amdgpu hwmon4=it8622
line=$(grep -E '^DEVNAME=' "$CONF" | head -n1 | sed 's/^DEVNAME=//') || true
for pair in $line; do
    k=${pair%%=*}; v=${pair#*=}
    case $v in
        amdgpu) old_amd=$k ;;
        it8*)   old_it=$k ;;
    esac
done

# Fallback: DEVPATH=hwmon3=devices/... hwmon4=devices/platform/it87.2624
if [[ -z $old_amd || -z $old_it ]]; then
    line=$(grep -E '^DEVPATH=' "$CONF" | head -n1 | sed 's/^DEVPATH=//') || true
    for pair in $line; do
        k=${pair%%=*}; v=${pair#*=}
        [[ -n $old_amd || $v == "$AMDGPU_DEV_PATH" ]] || old_amd=$k
        [[ -n $old_it  || $v == "$IT87_DEV_PATH" ]]   || old_it=$k
    done
fi

[[ -n $old_amd ]] || die "cannot tell which hwmonN in $CONF is the amdgpu device (no matching DEVNAME/DEVPATH line)"
[[ -n $old_it ]]  || die "cannot tell which hwmonN in $CONF is the IT87 device (no matching DEVNAME/DEVPATH line)"

# --- 3. Rewrite the config --------------------------------------------------
if [[ $old_amd == "$new_amd" && $old_it == "$new_it" ]]; then
    log "$CONF already aligned (amdgpu=$new_amd, it87=$new_it); nothing to do"
else
    log "re-aligning $CONF: amdgpu $old_amd -> $new_amd, it87 $old_it -> $new_it"
    TMP=$(mktemp -- "${CONF}.XXXXXX")
    # Two-phase rewrite via placeholders so swapped numbers cannot clobber
    # each other (hwmon3 <-> hwmon4 style).
    sed -e "s/\\b${old_amd}\\b/__HWAMD__/g" \
        -e "s/\\b${old_it}\\b/__HWIT__/g" \
        -e "s/__HWAMD__/${new_amd}/g" \
        -e "s/__HWIT__/${new_it}/g" \
        -- "$CONF" > "$TMP"
    grep -q '^DEVPATH=' "$TMP" || die "generated config lost its DEVPATH line; keeping old config"
    cp -p -- "$CONF" "${CONF}.bak"
    cat -- "$TMP" > "$CONF"
    rm -f -- "$TMP"; TMP=""
fi
log "DEVPATH: $(grep -E '^DEVPATH=' "$CONF" | head -n1)"

# --- 4. (Re)start fancontrol -------------------------------------------------
if (( DO_START )); then
    if command -v systemctl >/dev/null 2>&1 && systemctl cat "$SERVICE" >/dev/null 2>&1; then
        if systemctl is-active --quiet "$SERVICE"; then
            log "restarting $SERVICE"
            systemctl restart "$SERVICE"
        else
            log "starting $SERVICE"
            systemctl start "$SERVICE"
        fi
    elif command -v fancontrol >/dev/null 2>&1; then
        # No systemd unit for fancontrol: manage the process directly.
        local_pidfile=/var/run/fancontrol.pid
        if [[ -f $local_pidfile ]]; then
            pid=$(<"$local_pidfile") 2>/dev/null || pid=""
            if [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
                log "stopping running fancontrol (pid $pid)"
                kill "$pid" 2>/dev/null || true
                for _ in 1 2 3 4 5 6 7 8 9 10; do
                    kill -0 "$pid" 2>/dev/null || break
                    sleep 1
                done
                kill -9 "$pid" 2>/dev/null || true
            fi
        fi
        log "starting fancontrol"
        fancontrol
    else
        log "WARNING: no '$SERVICE' unit and no 'fancontrol' binary found; $CONF was updated but fancontrol was not started"
    fi
fi
log "done"
