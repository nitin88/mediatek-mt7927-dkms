# MT7927 Wi-Fi Enablement (Linux)

Local, reproducible, rollback-safe tooling for MediaTek MT7927 (Filogic 380) Wi-Fi on Linux.

## Status

**Experimental** — MT7927 has no upstream Linux support. This uses out-of-tree DKMS modules and firmware extracted from Windows drivers.

## Hardware compatibility

| PCI ID | Device | Notes |
|--------|--------|-------|
| `14c3:7927` | MT7927 (ASUS, MSI, etc.) | Primary target |
| `14c3:6639` | MT6639 / Foxconn / Azurewave | Internal chip ID |
| `14c3:0738` | AMD RZ738 (MediaTek MT7927) | AMD variant |

MT7927 is a combo chip: WiFi via PCIe (mt7925e driver) + Bluetooth via USB (btusb).

## Kernel matrix

| Distro | Kernel | Wi-Fi | BT | Notes |
|--------|--------|-------|-----|-------|
| Fedora 43 | 6.18.x | Target | Deferred | Primary development target |

## Quickstart

```bash
# 1. Install dependencies
sudo ./scripts/install-deps.sh

# 2. Install firmware (extracts from mediatek_wifi.zip)
sudo ./scripts/install-firmware.sh

# 3. Build and install DKMS module
sudo ./scripts/install-wifi.sh

# 4. Reboot
sudo reboot

# 5. Verify
./scripts/verify.sh
```

Installer scripts are **sudo-user only**. Run them with `sudo` from your normal user shell, not from a direct root shell, so cache ownership stays compatible with non-root maintenance workflows.

If Secure Boot is enabled and you intentionally want to continue anyway:

```bash
sudo ./scripts/install-wifi.sh --allow-secure-boot
```

## mt76 Source Policy

- **Default (safe):** `install-wifi.sh` uses a pinned mt76 kernel snapshot + pinned SHA256 from `dkms/mt76-source.conf`.
- **Download behavior:** `install-wifi.sh` reuses local cache from `.cache/kernel-snapshots/` when SHA256 matches the pin.
- **Ownership behavior:** when run via `sudo`, `install-wifi.sh` normalizes cache ownership back to the invoking sudo user.
- **Opt-in updates:** use `scripts/update-mt76-pin.sh` to refresh the pin to a newer kernel snapshot after patch dry-run validation.

```bash
# Example: propose and apply a new mt76 pin (opt-in)
./scripts/update-mt76-pin.sh 6.19.4
```

## Uninstall / Rollback

```bash
# Remove everything
sudo ./scripts/uninstall-all.sh
sudo reboot

# Or individually:
sudo ./scripts/uninstall-wifi.sh      # DKMS module only
sudo ./scripts/uninstall-firmware.sh   # firmware only (restores backup)
```

## Repository layout

```
mt7927/
├── agents.md                    — agent definitions and project spec
├── README.md                    — this file
├── REVIEW.md                    — adversarial review checklist
├── mediatek-mt7927-dkms/        — jetm DKMS repo (pinned at 1e16b60)
├── mediatek_wifi.zip            — MSI WiFi driver (not in git)
├── mediatek_bt.zip              — MSI BT driver (not in git)
├── scripts/
│   ├── install-deps.sh          — install build dependencies (dnf)
│   ├── install-firmware.sh      — extract and install firmware
│   ├── install-wifi.sh          — build and install DKMS module
│   ├── update-mt76-pin.sh       — opt-in mt76 pin updater (with patch dry-run validation)
│   ├── uninstall-wifi.sh        — remove DKMS module
│   ├── uninstall-firmware.sh    — restore firmware from backup
│   ├── uninstall-all.sh         — full uninstall
│   ├── verify.sh                — PASS/FAIL diagnostics
│   └── experimental/            — boot timing workarounds (disabled)
└── firmware/
    ├── PROVENANCE.md            — firmware source and hashes
    └── SHA256SUMS               — canonical expected WiFi blob hashes (tracked)
```

## How it works

1. **Firmware**: Extracted from MSI Windows driver package (`mtkwlan.dat`) using `extract_firmware.py`. Installed to `/lib/firmware/mediatek/mt7927/`.

2. **Driver**: mt76 WiFi source is fetched from a **pinned kernel snapshot** (`dkms/mt76-source.conf`), SHA256-verified, cache-aware (`.cache/kernel-snapshots/`), patched with MT6639/MT7927 support (chip init, DMA, connection state fix), and installed via WiFi-only DKMS.

3. **Patches applied** (from [jetm/mediatek-mt7927-dkms](https://github.com/jetm/mediatek-mt7927-dkms)):
   - `mt7902-wifi-6.19.patch` — MT7902/WiFi 6E (mt7921 driver)
   - `mt6639-wifi-init.patch` — MT6639 chip init (CBTOP, detection, DBDC)
   - `mt6639-wifi-dma.patch` — DMA ring layout + channel context
   - `mt7925-wifi-connstate.patch` — Connection state fix (EAPOL auth)

## Known issues

- **Bluetooth**: Requires separate BT patches (btusb/btmtk) + boot timing workaround for USB enumeration. Deferred.
- **Suspend/resume**: Untested — may require workarounds.
- **Kernel upgrades**: DKMS auto-rebuilds on kernel update, but major version changes may break patches. Run `verify.sh` after kernel updates.
- **Secure Boot**: `install-wifi.sh` fails by default when SB is enabled; use `--allow-secure-boot` only if you intentionally handle module signing yourself.

## Sources

- [jetm/mediatek-mt7927-dkms](https://github.com/jetm/mediatek-mt7927-dkms) — DKMS packaging and patches
- [Vitalie Miron gist](https://gist.github.com/vitaliemiron/c23d7b2e47ab67a7a0851f6ef0cada39) — end-to-end Ubuntu guide
- [openwrt/mt76#927](https://github.com/openwrt/mt76/issues/927) — upstream tracking issue
- [quiloos39/mt76-mt7927-fix](https://github.com/quiloos39/mt76-mt7927-fix) — connection state fix
- [NarKarapetyan93/mt7927-bluetooth-linux](https://github.com/NarKarapetyan93/mt7927-bluetooth-linux) — BT patches for Fedora


Huge Props to jetm/mediatek-mt7927-dkms for major work.
