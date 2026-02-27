# Adversarial Review — MT7927 Enablement

Per `agents.md` Agent 5 (Adversarial Reviewer): reduce risk of bricking networking or introducing unsafe practices.

## Checklist

### Pinning (no mutable upstream references)

- [x] jetm DKMS repo pinned at commit `1e16b60`
- [x] mt76 WiFi source pinned to kernel `v6.19.3`
- [x] MSI driver ZIPs SHA256-verified (`dd17e8d0...` / `2c4048df...`)
- [x] Extracted firmware blobs individually SHA256-verified
- [ ] Legacy PKGBUILD BT path (`dkms-patchmodule.sh`) fetches btusb source from kernel.org for running kernel version. Not used by default WiFi scripts.

### Firmware backup/restore

- [x] `install-firmware.sh` backs up existing `/lib/firmware/mediatek/mt7927/` before overwriting
- [x] `uninstall-firmware.sh` restores from preserved baseline backup (`/lib/firmware/mediatek/mt7927.original`)
- [x] Baseline backup is kept across cycles to preserve original rollback state

### No default-enabled boot hacks

- [x] No initramfs module insertion by default
- [x] No systemd service for xHCI unbind/rebind
- [x] `scripts/experimental/` exists but is empty (reserved for opt-in workarounds)

### Execution model

- [x] Installer scripts are sudo-user only (`sudo` from normal user shell), not direct root-shell workflows
- [x] `install-wifi.sh` normalizes mt76 cache ownership to sudo user for non-root `update-mt76-pin.sh` continuity

### Secure Boot

- [x] Target system has Secure Boot disabled — documented
- [x] `install-wifi.sh` fails by default when SB is enabled unless user passes `--allow-secure-boot`
- [x] `verify.sh` detects SB state and warns if unsigned DKMS modules are likely blocked

### Rollback safety

- [x] `uninstall-all.sh` removes DKMS modules and restores firmware
- [x] `uninstall-wifi.sh` and `uninstall-firmware.sh` work independently
- [x] dracut rebuilt once in full uninstall (`uninstall-all.sh`), or per-script when run standalone
- [x] depmod run after DKMS changes
- [ ] No automated check that a known-good kernel remains bootable. User responsibility.

### Network download during install

- [x] `install-firmware.sh` uses local ZIP — no network download
- [x] `install-wifi.sh` uses mt76 pinned snapshot + SHA256 verification, and reuses local cache when available (`.cache/kernel-snapshots/`)
- [ ] Legacy PKGBUILD BT path still has build-time network dependency (`dkms-patchmodule.sh`)
- **Risk**: kernel.org availability can still affect WiFi install on first uncached fetch and legacy BT DKMS path.

### Module conflicts

- [x] Install scripts unload existing mt76 modules before loading new ones
- [x] DKMS installs to `/updates/dkms/` which takes priority over in-tree modules
- [ ] In-tree mt76 modules not explicitly blacklisted. If DKMS module fails to load, kernel may fall back to in-tree module (which doesn't support MT7927). Acceptable: verify.sh catches this.

## Blocking issues

None currently. All items above are acceptable for local use with documented caveats.

## Recommendations (non-blocking)

1. Consider pre-bundling mt76 source tarball to eliminate build-time network dependency
2. Add `--dry-run` flag to install scripts for review before execution
3. Add explicit BT installer/uninstaller scripts to keep BT workflow opt-in and isolated
