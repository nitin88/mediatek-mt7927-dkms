#!/usr/bin/env bash
set -euo pipefail

# Install MT7927 WiFi firmware from MSI driver package
# Must be run as root
#
# Usage:
#   sudo ./install-firmware.sh                      # auto-find mediatek_wifi.zip in repo
#   sudo ./install-firmware.sh /path/to/driver.zip  # use specific ZIP

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (sudo $0)" >&2
    exit 1
fi

if [[ -z "${SUDO_UID:-}" || -z "${SUDO_GID:-}" ||
      ! "${SUDO_UID}" =~ ^[0-9]+$ || ! "${SUDO_GID}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Run this script via sudo from a normal user, not a direct root shell." >&2
    echo "       Example: sudo $0 [path/to/mediatek_wifi.zip]" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DKMS_DIR="${REPO_DIR}/mediatek-mt7927-dkms"
FW_DIR="${REPO_DIR}/firmware"

# Known ZIP hash (MSI package in this repository)
ZIP_SHA256="dd17e8d0f17932ee2e83a9c17b45cfa8c7841c5fa0b7c26c63e59629bfdfef2a"
HASH_MANIFEST="${FW_DIR}/SHA256SUMS"
BT_BLOB="BT_RAM_CODE_MT6639_2_1_hdr.bin"

# WiFi firmware files to install
WIFI_BLOBS=(
    "WIFI_MT6639_PATCH_MCU_2_1_hdr.bin"
    "WIFI_RAM_CODE_MT6639_2_1.bin"
)

FW_INSTALL_DIR="/lib/firmware/mediatek/mt7927"

manifest_sha_for_blob() {
    local blob="$1"
    awk -v f="$blob" '$2 == f {print $1; exit}' "${HASH_MANIFEST}"
}

# --- Locate driver ZIP ---
if [[ -n "${1:-}" ]]; then
    DRIVER_ZIP="$1"
else
    DRIVER_ZIP="${REPO_DIR}/mediatek_wifi.zip"
fi

if [[ ! -f "$DRIVER_ZIP" ]]; then
    echo "ERROR: Driver ZIP not found: ${DRIVER_ZIP}" >&2
    echo "Place mediatek_wifi.zip in the repo root or pass path as argument." >&2
    exit 1
fi

# --- Verify ZIP integrity ---
echo "==> Verifying driver ZIP integrity..."
ACTUAL_SHA256="$(sha256sum "$DRIVER_ZIP" | awk '{print $1}')"
if [[ "$ACTUAL_SHA256" != "$ZIP_SHA256" ]]; then
    echo "WARNING: ZIP SHA256 mismatch (different driver version?)" >&2
    echo "  Expected: ${ZIP_SHA256}" >&2
    echo "  Actual:   ${ACTUAL_SHA256}" >&2
    echo "  Proceeding anyway — firmware blobs will be verified individually." >&2
fi

# --- Extract mtkwlan.dat ---
WORK_DIR="$(mktemp -d /tmp/mt7927-fw.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "==> Extracting mtkwlan.dat from ZIP..."
unzip -o -q "$DRIVER_ZIP" "WIFI/mtkwlan.dat" -d "$WORK_DIR"

MTKWLAN="${WORK_DIR}/WIFI/mtkwlan.dat"
if [[ ! -f "$MTKWLAN" ]]; then
    echo "ERROR: WIFI/mtkwlan.dat not found in ZIP" >&2
    exit 1
fi

# --- Extract firmware blobs ---
EXTRACT_DIR="${WORK_DIR}/extracted"
echo "==> Extracting firmware blobs..."
python3 "${DKMS_DIR}/extract_firmware.py" "$MTKWLAN" "$EXTRACT_DIR"

# --- Verify extracted blobs ---
if [[ ! -f "${HASH_MANIFEST}" ]]; then
    echo "ERROR: Missing firmware hash manifest: ${HASH_MANIFEST}" >&2
    exit 1
fi

echo "==> Verifying extracted WiFi firmware..."
for blob in "${WIFI_BLOBS[@]}"; do
    BLOB_FILE="${EXTRACT_DIR}/${blob}"
    if [[ ! -f "$BLOB_FILE" ]]; then
        echo "ERROR: Expected blob not found: ${blob}" >&2
        exit 1
    fi
    EXPECTED="$(manifest_sha_for_blob "$blob")"
    if [[ -z "${EXPECTED}" ]]; then
        echo "ERROR: No SHA256 entry for ${blob} in ${HASH_MANIFEST}" >&2
        exit 1
    fi
    ACTUAL="$(sha256sum "$BLOB_FILE" | awk '{print $1}')"
    if [[ "$ACTUAL" != "$EXPECTED" ]]; then
        echo "ERROR: SHA256 mismatch for ${blob}" >&2
        echo "  Expected: ${EXPECTED}" >&2
        echo "  Actual:   ${ACTUAL}" >&2
        exit 1
    fi
    echo "  ${blob}: OK"
done

# Optional informational check: BT blob from the same package.
BT_BLOB_FILE="${EXTRACT_DIR}/${BT_BLOB}"
if [[ -f "${BT_BLOB_FILE}" ]]; then
    BT_EXPECTED_SHA256="$(manifest_sha_for_blob "${BT_BLOB}")"
    if [[ -z "${BT_EXPECTED_SHA256}" ]]; then
        echo "  WARNING: No SHA256 entry for ${BT_BLOB} in ${HASH_MANIFEST} (informational)" >&2
        BT_EXPECTED_SHA256="unknown"
    fi
    BT_ACTUAL_SHA256="$(sha256sum "${BT_BLOB_FILE}" | awk '{print $1}')"
    if [[ "${BT_EXPECTED_SHA256}" != "unknown" && "${BT_ACTUAL_SHA256}" == "${BT_EXPECTED_SHA256}" ]]; then
        echo "  ${BT_BLOB}: OK (informational)"
    else
        echo "  WARNING: ${BT_BLOB} SHA mismatch (informational; WiFi install continues)" >&2
    fi
else
    echo "  WARNING: ${BT_BLOB} not present (informational; WiFi install continues)" >&2
fi

# --- Backup existing firmware ---
# Use a named .original backup — only create it once to preserve the true original
ORIGINAL_BACKUP="${FW_INSTALL_DIR}.original"
BACKUP_STATUS="none (fresh install)"
if [[ -d "$FW_INSTALL_DIR" ]] && [[ ! -d "$ORIGINAL_BACKUP" ]]; then
    echo "==> Backing up original firmware to ${ORIGINAL_BACKUP}"
    cp -a "$FW_INSTALL_DIR" "$ORIGINAL_BACKUP"
    BACKUP_STATUS="${ORIGINAL_BACKUP} (created)"
elif [[ -d "$ORIGINAL_BACKUP" ]]; then
    echo "==> Original backup already exists at ${ORIGINAL_BACKUP} — preserving it"
    BACKUP_STATUS="${ORIGINAL_BACKUP} (preserved)"
fi

# --- Install WiFi firmware ---
echo "==> Installing WiFi firmware to ${FW_INSTALL_DIR}..."
mkdir -p "$FW_INSTALL_DIR"
for blob in "${WIFI_BLOBS[@]}"; do
    install -m644 "${EXTRACT_DIR}/${blob}" "${FW_INSTALL_DIR}/${blob}"
    EXPECTED="$(manifest_sha_for_blob "$blob")"
    ACTUAL="$(sha256sum "${FW_INSTALL_DIR}/${blob}" | awk '{print $1}')"
    if [[ "$ACTUAL" != "$EXPECTED" ]]; then
        echo "ERROR: Installed blob hash mismatch for ${blob}" >&2
        echo "  Expected: ${EXPECTED}" >&2
        echo "  Actual:   ${ACTUAL}" >&2
        exit 1
    fi
    echo "  Installed: ${blob}"
done

# --- Rebuild initramfs ---
echo "==> Rebuilding initramfs with dracut..."
dracut --force

echo ""
echo "==> Firmware installation complete."
echo "    Installed to: ${FW_INSTALL_DIR}"
echo "    Backup at:    ${BACKUP_STATUS}"
echo ""
echo "    Next step: sudo ./scripts/install-wifi.sh"
