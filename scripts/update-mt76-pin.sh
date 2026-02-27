#!/usr/bin/env bash
set -euo pipefail

# Opt-in pin updater for mt76 source snapshot used by install-wifi.sh.
# This script does NOT run during normal install flow.
#
# Usage:
#   ./scripts/update-mt76-pin.sh <kernel-version>          # validate and update pin
#   ./scripts/update-mt76-pin.sh <kernel-version> --force  # update even if patch apply fails
#   ./scripts/update-mt76-pin.sh <kernel-version> --refresh  # re-download snapshot, ignore cache

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <kernel-version> [--force] [--refresh]" >&2
    exit 1
fi

TARGET_KVER="$1"
shift

FORCE_UPDATE=0
REFRESH_CACHE=0
for opt in "$@"; do
    case "${opt}" in
        --force)
            FORCE_UPDATE=1
            ;;
        --refresh)
            REFRESH_CACHE=1
            ;;
        *)
            echo "ERROR: Unknown option: ${opt}" >&2
            echo "Usage: $0 <kernel-version> [--force] [--refresh]" >&2
            exit 1
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DKMS_DIR="${REPO_DIR}/mediatek-mt7927-dkms"
PIN_FILE="${REPO_DIR}/dkms/mt76-source.conf"
CACHE_DIR="${REPO_DIR}/.cache/kernel-snapshots"

for cmd in curl bsdtar patch sha256sum; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Missing required command: ${cmd}" >&2
        exit 1
    fi
done

WORK_DIR="$(mktemp -d /tmp/mt76-pin-update.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

CACHE_TARBALL="${CACHE_DIR}/linux-${TARGET_KVER}.tar.gz"
URL="https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/snapshot/linux-${TARGET_KVER}.tar.gz"
MT76_SRC="${WORK_DIR}/linux-${TARGET_KVER}/drivers/net/wireless/mediatek/mt76"

mkdir -p "${CACHE_DIR}"
if [[ ${REFRESH_CACHE} -eq 1 || ! -f "${CACHE_TARBALL}" ]]; then
    echo "==> Downloading linux snapshot for ${TARGET_KVER}..."
    curl -fL -o "${CACHE_TARBALL}.tmp" "${URL}"
    mv -f "${CACHE_TARBALL}.tmp" "${CACHE_TARBALL}"
else
    echo "==> Using cached snapshot: ${CACHE_TARBALL}"
fi

NEW_SHA256="$(sha256sum "${CACHE_TARBALL}" | awk '{print $1}')"
echo "==> Snapshot SHA256: ${NEW_SHA256}"

echo "==> Extracting mt76 subtree..."
bsdtar -xf "${CACHE_TARBALL}" -C "${WORK_DIR}"
if [[ ! -d "${MT76_SRC}" ]]; then
    echo "ERROR: mt76 subtree not found at ${MT76_SRC}" >&2
    exit 1
fi

echo "==> Validating patch applicability (sequential apply in temp tree)..."
PATCHES=(
    "mt7902-wifi-6.19.patch"
    "mt6639-wifi-init.patch"
    "mt6639-wifi-dma.patch"
    "mt7925-wifi-connstate.patch"
)

PATCH_OK=1
for patch_name in "${PATCHES[@]}"; do
    patch_file="${DKMS_DIR}/${patch_name}"
    if [[ ! -f "${patch_file}" ]]; then
        echo "ERROR: Missing patch file: ${patch_file}" >&2
        exit 1
    fi

    if patch -p1 --forward -d "${MT76_SRC}" < "${patch_file}" >/dev/null; then
        echo "  ${patch_name}: OK"
    else
        echo "  ${patch_name}: FAIL" >&2
        PATCH_OK=0
    fi
done

if [[ ${PATCH_OK} -eq 0 && ${FORCE_UPDATE} -ne 1 ]]; then
    echo "ERROR: One or more patches failed to apply. Pin not updated." >&2
    echo "       Re-run with --force only if you intentionally want a broken/unvalidated pin." >&2
    exit 1
fi

if [[ ${PATCH_OK} -eq 0 ]]; then
    echo "WARNING: Proceeding with --force despite patch failures." >&2
fi

echo "==> Updating ${PIN_FILE}..."
cat > "${PIN_FILE}" <<EOF
# Pinned mt76 source snapshot for Wi-Fi installer.
# Update intentionally via scripts/update-mt76-pin.sh after validation.
MT76_KVER="${TARGET_KVER}"
MT76_TARBALL_SHA256="${NEW_SHA256}"
EOF

echo "==> Pin update complete."
echo "    MT76_KVER=${TARGET_KVER}"
echo "    MT76_TARBALL_SHA256=${NEW_SHA256}"
