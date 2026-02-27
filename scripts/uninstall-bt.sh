#!/usr/bin/env bash
set -euo pipefail

# Remove MT7927 Bluetooth DKMS modules and restore BT firmware backup.

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (sudo $0)" >&2
    exit 1
fi

PKG_NAME="mediatek-mt7927-bt"
PKG_VERSION="1.0"
DKMS_SRC="/usr/src/${PKG_NAME}-${PKG_VERSION}"
FW_DIR="/lib/firmware/mediatek/mt6639"
ORIGINAL_BACKUP="${FW_DIR}.original"

echo "==> Removing MT7927 Bluetooth DKMS modules..."

echo "==> Unloading btusb/btmtk..."
modprobe -r btusb btmtk 2>/dev/null || true

if dkms status "${PKG_NAME}/${PKG_VERSION}" 2>/dev/null | grep -q "${PKG_NAME}"; then
    echo "==> DKMS remove..."
    dkms remove "${PKG_NAME}/${PKG_VERSION}" --all
else
    echo "==> DKMS module not registered (already removed?)"
fi

if [[ -d "${DKMS_SRC}" ]]; then
    echo "==> Removing source tree: ${DKMS_SRC}"
    rm -rf "${DKMS_SRC}"
fi

echo "==> Restoring BT firmware..."
if [[ -d "${FW_DIR}" ]]; then
    rm -rf "${FW_DIR}"
fi

if [[ -d "${ORIGINAL_BACKUP}" ]]; then
    cp -a "${ORIGINAL_BACKUP}" "${FW_DIR}"
    echo "  Restored from ${ORIGINAL_BACKUP}"
else
    echo "  No original backup found; BT firmware directory removed."
fi

echo "==> Running depmod..."
depmod -a

if [[ "${SKIP_DRACUT:-0}" == "1" ]]; then
    echo "==> SKIP_DRACUT=1 set, skipping initramfs rebuild in uninstall-bt.sh"
else
    echo "==> Rebuilding initramfs..."
    dracut --force
fi

echo ""
echo "==> Bluetooth uninstall complete."
echo "    Reboot to fully clear loaded modules."
