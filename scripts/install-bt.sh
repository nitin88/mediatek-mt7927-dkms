#!/usr/bin/env bash
set -euo pipefail

# Build and install MT7927 Bluetooth DKMS modules on Fedora.
# Based on patch logic from:
#   https://github.com/NarKarapetyan93/mt7927-bluetooth-linux

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (sudo $0)" >&2
    exit 1
fi

if [[ -z "${SUDO_UID:-}" || -z "${SUDO_GID:-}" ||
      ! "${SUDO_UID}" =~ ^[0-9]+$ || ! "${SUDO_GID}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Run this script via sudo from a normal user, not a direct root shell." >&2
    echo "       Example: sudo $0 [--allow-secure-boot] [path/to/mediatek_bt.zip]" >&2
    exit 1
fi

ALLOW_SECURE_BOOT=0
DRIVER_ZIP_ARG=""
for opt in "$@"; do
    case "${opt}" in
        --allow-secure-boot)
            ALLOW_SECURE_BOOT=1
            ;;
        -h|--help)
            echo "Usage: $0 [--allow-secure-boot] [path/to/mediatek_bt.zip]"
            echo "  --allow-secure-boot  Continue even if Secure Boot is enabled"
            exit 0
            ;;
        -*)
            echo "ERROR: Unknown option: ${opt}" >&2
            echo "Usage: $0 [--allow-secure-boot] [path/to/mediatek_bt.zip]" >&2
            exit 1
            ;;
        *)
            if [[ -n "${DRIVER_ZIP_ARG}" ]]; then
                echo "ERROR: Multiple ZIP paths provided; use only one." >&2
                exit 1
            fi
            DRIVER_ZIP_ARG="${opt}"
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
JETM_DIR="${REPO_DIR}/mediatek-mt7927-dkms"

DKMS_CONF_SRC="${REPO_DIR}/dkms/dkms-bt.conf"
DKMS_PRE_BUILD="${JETM_DIR}/dkms-patchmodule.sh"
BT_PATCH="${JETM_DIR}/mt6639-bt-6.19.patch"

PKG_NAME="mediatek-mt7927-bt"
PKG_VERSION="1.0"
DKMS_SRC="/usr/src/${PKG_NAME}-${PKG_VERSION}"

KVER="$(uname -r)"
FW_INSTALL_DIR="/lib/firmware/mediatek/mt6639"
FW_BLOB="BT_RAM_CODE_MT6639_2_1_hdr.bin"

# MSI BT package currently present in this repository.
ZIP_SHA256="2c4048dfbe1c73969e510448d1f022ce5f0332479c89996d3af09bab354d7e70"
FW_BLOB_SHA256="27c6a38598176e3dde7baa87d0749aec12013db29cbaec97db14079abce5079f"

if [[ -n "${DRIVER_ZIP_ARG}" ]]; then
    DRIVER_ZIP="${DRIVER_ZIP_ARG}"
else
    DRIVER_ZIP="${REPO_DIR}/mediatek_bt.zip"
fi

echo "==> MT7927 Bluetooth DKMS installer"
echo "    Kernel:      ${KVER}"
echo "    DKMS:        ${PKG_NAME}/${PKG_VERSION}"
echo "    Driver ZIP:  ${DRIVER_ZIP}"
echo ""

for cmd in dkms make gcc curl patch sha256sum unzip python3; do
    if ! command -v "${cmd}" &>/dev/null; then
        echo "ERROR: ${cmd} not found. Run ./scripts/install-deps.sh first." >&2
        exit 1
    fi
done

for required in "${DKMS_CONF_SRC}" "${DKMS_PRE_BUILD}" "${BT_PATCH}"; do
    if [[ ! -f "${required}" ]]; then
        echo "ERROR: Missing required file: ${required}" >&2
        exit 1
    fi
done

KDEV="/usr/src/kernels/${KVER}"
if [[ ! -d "${KDEV}" ]]; then
    echo "ERROR: kernel-devel not found at ${KDEV}" >&2
    echo "Run: sudo dnf install kernel-devel-${KVER}" >&2
    exit 1
fi

if command -v mokutil &>/dev/null; then
    SB_STATE="$(mokutil --sb-state 2>/dev/null || true)"
    if [[ "${SB_STATE}" == *"SecureBoot enabled"* ]]; then
        if [[ ${ALLOW_SECURE_BOOT} -ne 1 ]]; then
            echo "ERROR: Secure Boot is enabled." >&2
            echo "       Unsigned out-of-tree DKMS modules are typically blocked from loading." >&2
            echo "       Disable Secure Boot, sign modules, or re-run with --allow-secure-boot." >&2
            exit 1
        fi
        echo "WARNING: Secure Boot is enabled, proceeding due to --allow-secure-boot."
        echo "         Modules may still fail to load unless signed."
    fi
fi

if [[ ! -f "${DRIVER_ZIP}" ]]; then
    echo "ERROR: Driver ZIP not found: ${DRIVER_ZIP}" >&2
    echo "Place mediatek_bt.zip in the repo root or pass its path explicitly." >&2
    exit 1
fi

echo "==> Verifying BT driver ZIP integrity..."
ZIP_ACTUAL_SHA256="$(sha256sum "${DRIVER_ZIP}" | awk '{print $1}')"
if [[ "${ZIP_ACTUAL_SHA256}" != "${ZIP_SHA256}" ]]; then
    echo "WARNING: ZIP SHA256 mismatch (different driver version?)" >&2
    echo "  Expected: ${ZIP_SHA256}" >&2
    echo "  Actual:   ${ZIP_ACTUAL_SHA256}" >&2
    echo "  Proceeding anyway — extracted BT blob will be hash-verified." >&2
fi

WORK_DIR="$(mktemp -d /tmp/mt7927-bt-build.XXXXXX)"
trap 'rm -rf "${WORK_DIR}"' EXIT

echo "==> Extracting BT firmware container (mtkbt.dat)..."
BT_DAT_ENTRY="$(unzip -Z1 "${DRIVER_ZIP}" | grep -iE '(^|/)mtkbt\.dat$' | head -1 || true)"
if [[ -z "${BT_DAT_ENTRY}" ]]; then
    echo "ERROR: mtkbt.dat not found in ${DRIVER_ZIP}" >&2
    exit 1
fi
unzip -o -q "${DRIVER_ZIP}" "${BT_DAT_ENTRY}" -d "${WORK_DIR}"
BT_DAT_PATH="${WORK_DIR}/${BT_DAT_ENTRY}"

if [[ ! -f "${BT_DAT_PATH}" ]]; then
    echo "ERROR: Extracted mtkbt.dat not found at ${BT_DAT_PATH}" >&2
    exit 1
fi

EXTRACTED_BT_BLOB="${WORK_DIR}/${FW_BLOB}"
python3 - "${BT_DAT_PATH}" "${EXTRACTED_BT_BLOB}" <<'PYEOF'
import struct
import sys

src = sys.argv[1]
dst = sys.argv[2]

with open(src, "rb") as f:
    data = f.read()

hdr_offset = 0x10
data_offset = struct.unpack_from("<I", data, hdr_offset + 64)[0]
data_size = struct.unpack_from("<I", data, hdr_offset + 68)[0]
blob = data[data_offset:data_offset + data_size]

if len(blob) != data_size:
    raise RuntimeError(f"BT blob size mismatch: expected {data_size}, got {len(blob)}")

with open(dst, "wb") as out:
    out.write(blob)
PYEOF

echo "==> Verifying extracted BT firmware..."
BT_ACTUAL_SHA256="$(sha256sum "${EXTRACTED_BT_BLOB}" | awk '{print $1}')"
if [[ "${BT_ACTUAL_SHA256}" != "${FW_BLOB_SHA256}" ]]; then
    echo "ERROR: BT firmware hash mismatch" >&2
    echo "  Expected: ${FW_BLOB_SHA256}" >&2
    echo "  Actual:   ${BT_ACTUAL_SHA256}" >&2
    exit 1
fi

ORIGINAL_BACKUP="${FW_INSTALL_DIR}.original"
if [[ -d "${FW_INSTALL_DIR}" && ! -d "${ORIGINAL_BACKUP}" ]]; then
    echo "==> Backing up original BT firmware to ${ORIGINAL_BACKUP}"
    cp -a "${FW_INSTALL_DIR}" "${ORIGINAL_BACKUP}"
elif [[ -d "${ORIGINAL_BACKUP}" ]]; then
    echo "==> Original BT firmware backup already exists at ${ORIGINAL_BACKUP}"
fi

echo "==> Installing BT firmware to ${FW_INSTALL_DIR}..."
mkdir -p "${FW_INSTALL_DIR}"
install -m644 "${EXTRACTED_BT_BLOB}" "${FW_INSTALL_DIR}/${FW_BLOB}"

INSTALLED_BT_SHA256="$(sha256sum "${FW_INSTALL_DIR}/${FW_BLOB}" | awk '{print $1}')"
if [[ "${INSTALLED_BT_SHA256}" != "${FW_BLOB_SHA256}" ]]; then
    echo "ERROR: Installed BT firmware hash mismatch" >&2
    exit 1
fi

echo "==> Removing previous DKMS installation (if any)..."
dkms remove "${PKG_NAME}/${PKG_VERSION}" --all 2>/dev/null || true

if [[ -d "${DKMS_SRC}" ]]; then
    echo "==> Removing old source tree at ${DKMS_SRC}..."
    rm -rf "${DKMS_SRC}"
fi

echo "==> Installing BT DKMS source tree to ${DKMS_SRC}..."
mkdir -p "${DKMS_SRC}"
install -m644 "${DKMS_CONF_SRC}" "${DKMS_SRC}/dkms.conf"
install -m755 "${DKMS_PRE_BUILD}" "${DKMS_SRC}/dkms-patchmodule.sh"
install -m644 "${BT_PATCH}" "${DKMS_SRC}/mt6639-bt-6.19.patch"

echo "==> DKMS add..."
dkms add "${PKG_NAME}/${PKG_VERSION}"

echo "==> Building and installing for installed kernels..."
installed_count=0
running_kernel_installed=0
while IFS= read -r kv; do
    [[ -n "${kv}" ]] || continue
    if [[ ! -d "/usr/src/kernels/${kv}" ]]; then
        echo "  Skipping ${kv}: kernel-devel not installed"
        continue
    fi

    echo "  DKMS install for ${kv}..."
    dkms install "${PKG_NAME}/${PKG_VERSION}" -k "${kv}"
    installed_count=$((installed_count + 1))
    if [[ "${kv}" == "${KVER}" ]]; then
        running_kernel_installed=1
    fi
done < <(find /lib/modules -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)

if [[ ${installed_count} -eq 0 ]]; then
    echo "ERROR: No kernel got BT DKMS installation (missing kernel-devel?)" >&2
    exit 1
fi

if [[ ${running_kernel_installed} -ne 1 ]]; then
    echo "ERROR: BT DKMS was not installed for running kernel ${KVER}" >&2
    exit 1
fi

echo "==> Running depmod..."
depmod -a

echo "==> Rebuilding initramfs..."
dracut --force

echo "==> Attempting to load btusb/btmtk..."
modprobe -r btusb btmtk 2>/dev/null || true
modprobe btusb 2>/dev/null || true

echo ""
echo "==> Bluetooth DKMS installation complete."
echo "    Firmware:    ${FW_INSTALL_DIR}/${FW_BLOB}"
echo "    DKMS source: ${DKMS_SRC}"
echo "    Module:      ${PKG_NAME}/${PKG_VERSION}"
echo ""
echo "    Next steps:"
echo "      1. Reboot: sudo reboot"
echo "      2. Verify BT: ./scripts/verify-bt.sh"
