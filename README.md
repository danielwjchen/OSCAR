# fancontrol-realign

Fixes a common post-reboot problem for [`fancontrol`](https://github.com/mkottman/fancontrol):
the `hwmon` numbers in `/etc/fancontrol` no longer match reality.

## The problem

Entries under `/sys/class/hwmon/` (`hwmon0` … `hwmonN`) are assigned in kernel
probe order, so **their numbers can change between boots** while the underlying
devices stay the same:

```
hwmon3 -> ../../devices/pci0000:00/0000:00:03.1/0000:07:00.0/0000:08:00.0/0000:09:00.0/hwmon/hwmon3
hwmon4 -> ../../devices/platform/it87.2624/hwmon/hwmon4
```

After a restart the same devices might be `hwmon1` and `hwmon2`. A
`/etc/fancontrol` that pins `hwmon3=amdgpu` / `hwmon4=it8622` then silently
reads temperatures and drives PWMs on the **wrong devices** (or finds nothing
at all) — and the fans spin at whatever the fallback gives you.

The *device paths* in the symlinks are stable; only the `hwmonN` names churn.
This project is a small bash script that re-derives the current numbers at
boot and rewrites `/etc/fancontrol` to match, then (re)starts fancontrol.

## Hardware targeted

- **Temperature source:** AMD GPU —
  `devices/pci0000:00/0000:00:03.1/0000:07:00.0/0000:08:00.0/0000:09:00.0` (hwmon name `amdgpu`)
- **Fan controller:** IT87 (IT8622) —
  `devices/platform/it87.2624` (hwmon name `it8622`), controlling `pwm2`/`pwm3`

See [`fancontrol`](fancontrol) for a sample `/etc/fancontrol` and
[`ls-output`](ls-output) for a sample `ls -l /sys/class/hwmon/` from the target
system.

## Files

| File | Purpose |
|---|---|
| `fancontrol-realign.sh` | The re-alignment script (runs as root at boot) |
| `fancontrol-realign.service` | Example systemd oneshot unit for boot |
| `test-fancontrol-realign.sh` | Self-test: builds a fake hwmon tree and checks the rewritten config |
| `fancontrol` | Sample `/etc/fancontrol` (the config the script rewrites) |
| `ls-output` | Sample `ls -l /sys/class/hwmon/` output from the target system |

## How it works

1. **Locate** — scans `/sys/class/hwmon/`, resolves each symlink, and matches
   each target device by its **stable sysfs device path**. If the path match
   fails (e.g. topology changed), it falls back to matching the driver name in
   `<hwmon>/name` (`amdgpu`, `it8622|it87`). Because drivers can probe late at
   boot, the search retries every 2 s for up to 60 s before giving up.
2. **Rewrite** — reads the current `DEVNAME=` / `DEVPATH=` lines of
   `/etc/fancontrol` to learn which `hwmonN` token is used for each device
   today, then rewrites *every* occurrence of those tokens across the whole
   file (`DEVPATH`, `DEVNAME`, `FCTEMPS`, `FCFANS`, `MINTEMP`, `MAXTEMP`,
   `MINSTART`, `MINSTOP`, `MINPWM`, `MAXPWM`). The rewrite is done in two
   phases via placeholders, so a full number swap (`hwmon3 ↔ hwmon4`) cannot
   clobber itself. All thresholds and other settings are preserved. A rolling
   backup of the pre-realign config is kept at `/etc/fancontrol.bak`. If the
   config is already aligned, nothing is touched.
3. **(Re)start** — restarts the `fancontrol` systemd unit if it is active,
   starts it if not; if no unit exists it stops a stale `fancontrol` process
   (via `/var/run/fancontrol.pid`) and launches the `fancontrol` binary
   directly.

## Installation

### Option A — standalone oneshot unit (recommended)

The script takes care of starting fancontrol itself:

```sh
install -m 0755 fancontrol-realign.sh /usr/local/sbin/fancontrol-realign.sh
install -m 0644 fancontrol-realign.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable fancontrol-realign
```

The unit runs `After=local-fs.target`, `Before=fancontrol.service`, and exits
non-zero (visible in `journalctl`) if the hwmon devices never appear within
the wait window.

### Option B — hook into an existing fancontrol.service

If you already run fancontrol from its own unit, add a drop-in override at
`/etc/systemd/system/fancontrol.service.d/override.conf`:

```ini
[Service]
ExecStartPre=/usr/local/sbin/fancontrol-realign.sh --no-start
```

then run `systemctl daemon-reload`.

`--no-start` skips step 3, because the unit's own `ExecStart` launches
fancontrol with the freshly rewritten config.

### Manual run

```sh
sudo fancontrol-realign.sh            # re-align + (re)start fancontrol
sudo fancontrol-realign.sh --no-start # re-align only
fancontrol-realign.sh --help
```

Safe to run at any time — if the config is already aligned it is a no-op
apart from (re)starting the service.

## Configuration

Everything is overridable without editing the script:

| Environment variable | Default | Meaning |
|---|---|---|
| `FANCONTROL_CONF` | `/etc/fancontrol` | Config file to rewrite |
| `FANCONTROL_HWMON_DIR` | `/sys/class/hwmon` | hwmon class directory to scan |
| `FANCONTROL_SERVICE` | `fancontrol` | systemd unit name to (re)start |
| `FANCONTROL_MAX_WAIT` | `60` | Seconds to wait for the hwmon devices to appear |

The device identities themselves are constants at the top of
`fancontrol-realign.sh`. If your GPU/IT87 sit at different PCI/platform IDs
than the sample, edit these four lines:

```sh
AMDGPU_DEV_PATH="devices/pci0000:00/0000:00:03.1/0000:07:00.0/0000:08:00.0/0000:09:00.0"
AMDGPU_NAME_RE='^amdgpu$'
IT87_DEV_PATH="devices/platform/it87.2624"
IT87_NAME_RE='^it8622$|^it87$'
```

Tip: find your real values with `ls -l /sys/class/hwmon/` and
`cat /sys/class/hwmon/hwmonN/name`.

## Testing

```sh
bash test-fancontrol-realign.sh [path-to-sample-fancontrol]
```

The harness builds a fake `/sys/class/hwmon` tree in a temp dir (using the
sample config as input) and asserts on the rewritten file. It covers:

- **shifted** numbers (`hwmon3→hwmon1`, `hwmon4→hwmon2`) — every key in every
  config line is remapped, distractor devices are ignored, backup is written
- **swapped** numbers (`hwmon3 ↔ hwmon4`) — the two-phase rewrite survives a
  full swap without clobbering
- **already aligned** — config untouched, no backup created
- **devices missing** — times out with a non-zero exit, config left untouched

## Troubleshooting

| Symptom | Check |
|---|---|
| `timed out after 60s; found amdgpu=<none>` | `ls -l /sys/class/hwmon/` — is the amdgpu/it87 device present at all? Load the drivers (`modprobe amdgpu`, `it87`) and see `dmesg`. Increase `FANCONTROL_MAX_WAIT` if probing is slow. |
| `cannot tell which hwmonN in /etc/fancontrol is ...` | Your config's `DEVNAME=`/`DEVPATH=` lines don't mention `amdgpu`/`it8*` or the expected device path. Verify the `DEVNAME` line, e.g. `DEVNAME=hwmon3=amdgpu hwmon4=it8622`. |
| Fans still misbehaving after re-align | Compare the logged `DEVPATH:` line against `ls -l /sys/class/hwmon/`; check `/etc/fancontrol.bak` to see what changed. |
| Script ran but fancontrol didn't start | No `fancontrol` unit and no `fancontrol` binary in `PATH` — the script logs a `WARNING:` in that case. Check `journalctl -u fancontrol-realign`. |
