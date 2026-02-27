#!/usr/bin/env bash
set -euo pipefail

# Remove all MT7927 components (WiFi DKMS + firmware)
# Must be run as root

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (sudo $0)" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Full MT7927 uninstall"
echo ""

echo "=== Step 1: Remove WiFi DKMS module ==="
SKIP_DRACUT=1 "${SCRIPT_DIR}/uninstall-wifi.sh"
echo ""

if [[ -x "${SCRIPT_DIR}/uninstall-bt.sh" ]]; then
    echo "=== Step 2: Remove BT DKMS module ==="
    SKIP_DRACUT=1 "${SCRIPT_DIR}/uninstall-bt.sh"
    echo ""
fi

echo "=== Step 3: Remove firmware ==="
SKIP_DRACUT=1 "${SCRIPT_DIR}/uninstall-firmware.sh"
echo ""

echo "=== Step 4: Rebuild initramfs once ==="
dracut --force
echo ""

echo "========================================"
echo " MT7927 fully uninstalled."
echo " Reboot to return to clean state."
echo "========================================"
