# Firmware Provenance

## Source

- **Vendor**: MSI (Micro-Star International)
- **Board**: MSI motherboard with MediaTek MT7927 (Filogic 380)
- **Download page**: MSI support page for the specific motherboard model
- **Date acquired**: 2026-02-27

## Driver packages

### WiFi driver

- **File**: `mediatek_wifi.zip`
- **Driver version**: 5.7.0.4669 (Sep 27, 2025)
- **SHA256**: `dd17e8d0f17932ee2e83a9c17b45cfa8c7841c5fa0b7c26c63e59629bfdfef2a`
- **Contains**: `WIFI/mtkwlan.dat` (firmware container, 20.8MB)

### Bluetooth driver

- **File**: `mediatek_bt.zip`
- **Driver version**: 1.1044.0.556 (Sep 17, 2025)
- **SHA256**: `2c4048dfbe1c73969e510448d1f022ce5f0332479c89996d3af09bab354d7e70`
- **Contains**: `BT/mtkbt.dat` (firmware container, 4.1MB)

## Extracted firmware blobs

Extracted using `extract_firmware.py` from [jetm/mediatek-mt7927-dkms](https://github.com/jetm/mediatek-mt7927-dkms) (commit `1e16b60`).

Both ZIPs produce identical firmware blobs (byte-for-byte verified).

| Blob | Size (bytes) | SHA256 |
|------|-------------|--------|
| `BT_RAM_CODE_MT6639_2_1_hdr.bin` | 574,421 | `27c6a38598176e3dde7baa87d0749aec12013db29cbaec97db14079abce5079f` |
| `WIFI_MT6639_PATCH_MCU_2_1_hdr.bin` | 299,488 | `2560b22b2216b42526750f47d6c7d926019382c49cd69f5362c727d4217dfed2` |
| `WIFI_RAM_CODE_MT6639_2_1.bin` | 1,596,848 | `ffd1b8557d8448f92400077ed10a7c323af5b3e29a75ce3fd3c31c49b75a5ae1` |

## Installation paths

- WiFi firmware: `/lib/firmware/mediatek/mt7927/`
- BT firmware: `/lib/firmware/mediatek/mt6639/` (deferred)

## Notes

- These are Windows driver firmware blobs repurposed for Linux. No Linux-native firmware distribution exists for MT7927.
- The firmware container format (`mtkwlan.dat`) is a proprietary MediaTek format with null-terminated name entries, timestamps, and offset/size pairs (little-endian u32).
- An alternative source exists on station-drivers.com (v25.030.3.0057, Jan 18, 2026) but did not resolve TX retransmission issues per community reports.
