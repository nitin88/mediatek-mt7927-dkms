#!/usr/bin/env bash
set -euo pipefail

# Remove MT7927 DKMS WiFi module
# Must be run as root

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (sudo $0)" >&2
    exit 1
fi

PKG_NAME="mediatek-mt7927"
PKG_VERSION="2.1"
DKMS_SRC="/usr/src/${PKG_NAME}-${PKG_VERSION}"

echo "==> Removing MT7927 WiFi DKMS module..."

# Unload modules first
echo "==> Unloading modules..."
for mod in mt7925e mt7925_common mt7921e mt7921_common mt792x_lib mt76_connac_lib mt76; do
    if lsmod | grep -q "^${mod//-/_}"; then
        modprobe -r "$mod" 2>/dev/null || true
        echo "  Unloaded: ${mod}"
    fi
done

# Remove DKMS module
if dkms status "${PKG_NAME}/${PKG_VERSION}" 2>/dev/null | grep -q "${PKG_NAME}"; then
    echo "==> DKMS remove..."
    dkms remove "${PKG_NAME}/${PKG_VERSION}" --all
else
    echo "==> DKMS module not registered (already removed?)"
fi

# Remove source tree
if [[ -d "$DKMS_SRC" ]]; then
    echo "==> Removing source tree: ${DKMS_SRC}"
    rm -rf "$DKMS_SRC"
fi

# Refresh module dependencies
echo "==> Running depmod..."
depmod -a

# Rebuild initramfs (skip when called by uninstall-all.sh)
if [[ "${SKIP_DRACUT:-0}" == "1" ]]; then
    echo "==> SKIP_DRACUT=1 set, skipping initramfs rebuild in uninstall-wifi.sh"
else
    echo "==> Rebuilding initramfs..."
    dracut --force
fi

echo ""
echo "==> WiFi DKMS module removed."
echo "    Reboot to fully clear loaded modules."
