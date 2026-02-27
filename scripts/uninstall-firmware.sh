#!/usr/bin/env bash
set -euo pipefail

# Restore MT7927 firmware from backup
# Must be run as root

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (sudo $0)" >&2
    exit 1
fi

FW_DIR="/lib/firmware/mediatek/mt7927"

echo "==> Removing MT7927 WiFi firmware..."

# Check for original backup
ORIGINAL_BACKUP="${FW_DIR}.original"

# Remove current firmware
if [[ -d "$FW_DIR" ]]; then
    echo "==> Removing ${FW_DIR}..."
    rm -rf "$FW_DIR"
fi

# Restore from .original backup if available (copy, don't move — preserve for future cycles)
if [[ -d "$ORIGINAL_BACKUP" ]]; then
    echo "==> Restoring from original backup: ${ORIGINAL_BACKUP}"
    cp -a "$ORIGINAL_BACKUP" "$FW_DIR"
    echo "  Restored. Original backup preserved at ${ORIGINAL_BACKUP}"
else
    echo "==> No original backup found — firmware removed without restore."
fi

# Clean up any legacy timestamped backups (from older install versions)
shopt -s nullglob
legacy_backups=("${FW_DIR}.bak."*)
shopt -u nullglob
for bak in "${legacy_backups[@]}"; do
    [[ -d "$bak" ]] || continue
    echo "==> Cleaning legacy backup: ${bak}"
    rm -rf "$bak"
done

# Rebuild initramfs (skip when called by uninstall-all.sh)
if [[ "${SKIP_DRACUT:-0}" == "1" ]]; then
    echo "==> SKIP_DRACUT=1 set, skipping initramfs rebuild in uninstall-firmware.sh"
else
    echo "==> Rebuilding initramfs..."
    dracut --force
fi

echo ""
echo "==> Firmware uninstall complete."
