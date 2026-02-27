#!/usr/bin/env bash
set -euo pipefail

# Build and install MT7927 WiFi DKMS module on Fedora
# Must be run as root
#
# This script:
# 1. Downloads mt76 WiFi source snapshot from kernel.org (version/hash pinned in dkms/mt76-source.conf)
# 2. Applies WiFi patches from the jetm DKMS repo
# 3. Creates Kbuild files for out-of-tree compilation
# 4. Installs into DKMS and builds against running kernel
#
# Based on: https://github.com/jetm/mediatek-mt7927-dkms (commit 1e16b60)

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (sudo $0)" >&2
    exit 1
fi

if [[ -z "${SUDO_UID:-}" || -z "${SUDO_GID:-}" ||
      ! "${SUDO_UID}" =~ ^[0-9]+$ || ! "${SUDO_GID}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Run this script via sudo from a normal user, not a direct root shell." >&2
    echo "       Example: sudo $0 [--allow-secure-boot]" >&2
    exit 1
fi

ALLOW_SECURE_BOOT=0
for opt in "$@"; do
    case "${opt}" in
        --allow-secure-boot)
            ALLOW_SECURE_BOOT=1
            ;;
        -h|--help)
            echo "Usage: $0 [--allow-secure-boot]"
            echo "  --allow-secure-boot  Continue even if Secure Boot is enabled"
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: ${opt}" >&2
            echo "Usage: $0 [--allow-secure-boot]" >&2
            exit 1
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DKMS_DIR="${REPO_DIR}/mediatek-mt7927-dkms"
MT76_PIN_FILE="${REPO_DIR}/dkms/mt76-source.conf"
MT76_CACHE_DIR="${REPO_DIR}/.cache/kernel-snapshots"
CACHE_OWNER="${SUDO_UID}:${SUDO_GID}"

# Pinned versions
# jetm/mediatek-mt7927-dkms commit: 1e16b60 (provenance reference)
if [[ ! -f "${MT76_PIN_FILE}" ]]; then
    echo "ERROR: Missing mt76 pin file: ${MT76_PIN_FILE}" >&2
    exit 1
fi
# shellcheck disable=SC1090
source "${MT76_PIN_FILE}"
if [[ -z "${MT76_KVER:-}" || -z "${MT76_TARBALL_SHA256:-}" ]]; then
    echo "ERROR: ${MT76_PIN_FILE} must define MT76_KVER and MT76_TARBALL_SHA256" >&2
    exit 1
fi

PKG_NAME="mediatek-mt7927"
PKG_VERSION="2.1"
DKMS_SRC="/usr/src/${PKG_NAME}-${PKG_VERSION}"

KVER="$(uname -r)"

echo "==> MT7927 WiFi DKMS installer"
echo "    Kernel:      ${KVER}"
echo "    mt76 source: v${MT76_KVER}"
echo "    DKMS:        ${PKG_NAME}/${PKG_VERSION}"
echo "    jetm commit: 1e16b60"
echo ""

# --- Verify dependencies ---
for cmd in dkms make gcc curl patch bsdtar sha256sum; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: ${cmd} not found. Run ./scripts/install-deps.sh first." >&2
        exit 1
    fi
done

KDEV="/usr/src/kernels/${KVER}"
if [[ ! -d "$KDEV" ]]; then
    echo "ERROR: kernel-devel not found at ${KDEV}" >&2
    echo "Run: sudo dnf install kernel-devel-${KVER}" >&2
    exit 1
fi

# Fail-safe Secure Boot handling: by default, abort if SB is enabled because
# unsigned out-of-tree modules commonly fail to load under SB enforcement.
# Users can explicitly override with --allow-secure-boot.
if command -v mokutil &>/dev/null; then
    SB_STATE="$(mokutil --sb-state 2>/dev/null || true)"
    if [[ "$SB_STATE" == *"SecureBoot enabled"* ]]; then
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

# --- Download mt76 source from kernel.org ---
ensure_cache_owner() {
    local path="$1"
    if [[ -e "${path}" ]]; then
        if ! chown "${CACHE_OWNER}" "${path}"; then
            echo "ERROR: Failed to set cache ownership on ${path} to ${CACHE_OWNER}" >&2
            return 1
        fi
    fi
}

download_mt76_source() {
    local kver="$1"
    local expected_sha="$2"
    local destdir="$3"

    local cache_tarball="${MT76_CACHE_DIR}/linux-${kver}.tar.gz"
    local tmp_tarball="${cache_tarball}.tmp"
    local url="https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/snapshot/linux-${kver}.tar.gz"
    local subtree="linux-${kver}/drivers/net/wireless/mediatek/mt76"
    local extract_root="${WORK_DIR}/extract"
    local src_root="${extract_root}/mt76"

    mkdir -p "${MT76_CACHE_DIR}"
    ensure_cache_owner "${MT76_CACHE_DIR}"

    if [[ -f "${cache_tarball}" ]]; then
        ensure_cache_owner "${cache_tarball}"
        local cached_sha
        cached_sha="$(sha256sum "${cache_tarball}" | awk '{print $1}')"
        if [[ "${cached_sha}" == "${expected_sha}" ]]; then
            echo "==> Using cached mt76 snapshot: ${cache_tarball}"
        else
            echo "==> Cached snapshot hash mismatch, refreshing cache..."
            rm -f "${cache_tarball}"
        fi
    fi

    if [[ ! -f "${cache_tarball}" ]]; then
        echo "==> Downloading pinned mt76 source snapshot: linux-${kver}.tar.gz"
        curl -fL -o "${tmp_tarball}" "${url}"
        mv -f "${tmp_tarball}" "${cache_tarball}"
        ensure_cache_owner "${cache_tarball}"
        ensure_cache_owner "${MT76_CACHE_DIR}"
    fi

    echo "==> Verifying snapshot SHA256..."
    local actual_sha
    actual_sha="$(sha256sum "${cache_tarball}" | awk '{print $1}')"
    if [[ "${actual_sha}" != "${expected_sha}" ]]; then
        echo "ERROR: mt76 snapshot hash mismatch" >&2
        echo "  Expected: ${expected_sha}" >&2
        echo "  Actual:   ${actual_sha}" >&2
        rm -f "${cache_tarball}"
        return 1
    fi

    echo "==> Extracting mt76 driver subtree only..."
    mkdir -p "${extract_root}" "${destdir}"
    bsdtar -xf "${cache_tarball}" -C "${extract_root}" --strip-components=5 "${subtree}"
    if [[ ! -d "${src_root}" ]]; then
        echo "ERROR: mt76 source path not found in snapshot: ${src_root}" >&2
        return 1
    fi

    cp -a "${src_root}/." "${destdir}/"
}

# --- Apply WiFi patches ---
apply_patches() {
    local srcdir="$1"

    local patches=(
        "mt7902-wifi-6.19.patch"
        "mt6639-wifi-init.patch"
        "mt6639-wifi-dma.patch"
        "mt7925-wifi-connstate.patch"
    )

    for p in "${patches[@]}"; do
        local patch_file="${DKMS_DIR}/${p}"
        if [[ ! -f "$patch_file" ]]; then
            echo "ERROR: Patch not found: ${patch_file}" >&2
            return 1
        fi
        echo "==> Applying ${p}..."
        if ! patch -p1 -d "$srcdir" --forward < "$patch_file"; then
            echo "ERROR: Patch ${p} failed to apply cleanly" >&2
            return 1
        fi
    done
}

# --- Create Kbuild files ---
create_kbuild() {
    local srcdir="$1"

    cat > "${srcdir}/Kbuild" <<'EOF'
obj-m += mt76.o
obj-m += mt76-connac-lib.o
obj-m += mt792x-lib.o
obj-m += mt7921/
obj-m += mt7925/

mt76-y := \
	mmio.o util.o trace.o dma.o mac80211.o debugfs.o eeprom.o \
	tx.o agg-rx.o mcu.o wed.o scan.o channel.o pci.o

mt76-connac-lib-y := mt76_connac_mcu.o mt76_connac_mac.o mt76_connac3_mac.o

mt792x-lib-y := mt792x_core.o mt792x_mac.o mt792x_trace.o \
		mt792x_debugfs.o mt792x_dma.o mt792x_acpi_sar.o

CFLAGS_trace.o := -I$(src)
CFLAGS_mt792x_trace.o := -I$(src)
EOF

    cat > "${srcdir}/mt7921/Kbuild" <<'EOF'
obj-m += mt7921-common.o
obj-m += mt7921e.o

mt7921-common-y := mac.o mcu.o main.o init.o debugfs.o
mt7921e-y := pci.o pci_mac.o pci_mcu.o
EOF

    cat > "${srcdir}/mt7925/Kbuild" <<'EOF'
obj-m += mt7925-common.o
obj-m += mt7925e.o

mt7925-common-y := mac.o mcu.o regd.o main.o init.o debugfs.o
mt7925e-y := pci.o pci_mac.o pci_mcu.o
EOF

    echo "==> Kbuild files created"
}

# --- Main ---

WORK_DIR="$(mktemp -d /tmp/mt7927-build.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

MT76_SRC="${WORK_DIR}/mt76"

# Step 1: Download mt76 source
download_mt76_source "$MT76_KVER" "$MT76_TARBALL_SHA256" "$MT76_SRC"

# Step 2: Apply patches
apply_patches "$MT76_SRC"

# Step 3: Create Kbuild files
create_kbuild "$MT76_SRC"

# Step 4: Remove previous DKMS installation if exists
if dkms status "${PKG_NAME}/${PKG_VERSION}" 2>/dev/null | grep -q "${PKG_NAME}"; then
    echo "==> Removing previous DKMS installation..."
    dkms remove "${PKG_NAME}/${PKG_VERSION}" --all 2>/dev/null || true
fi

if [[ -d "$DKMS_SRC" ]]; then
    echo "==> Removing old source tree at ${DKMS_SRC}..."
    rm -rf "$DKMS_SRC"
fi

# Step 5: Install DKMS source tree
echo "==> Installing DKMS source tree to ${DKMS_SRC}..."
mkdir -p "${DKMS_SRC}"

# Copy WiFi-only DKMS config (no BT modules, no PRE_BUILD)
install -m644 "${REPO_DIR}/dkms/dkms.conf" "${DKMS_SRC}/dkms.conf"

# Copy patched mt76 source tree
mkdir -p "${DKMS_SRC}/mt76/mt7921" "${DKMS_SRC}/mt76/mt7925"
install -m644 "${MT76_SRC}"/*.c "${MT76_SRC}"/*.h "${DKMS_SRC}/mt76/"
install -m644 "${MT76_SRC}/Kbuild" "${DKMS_SRC}/mt76/"
install -m644 "${MT76_SRC}/mt7921"/*.c "${MT76_SRC}/mt7921"/*.h "${DKMS_SRC}/mt76/mt7921/"
install -m644 "${MT76_SRC}/mt7921/Kbuild" "${DKMS_SRC}/mt76/mt7921/"
install -m644 "${MT76_SRC}/mt7925"/*.c "${MT76_SRC}/mt7925"/*.h "${DKMS_SRC}/mt76/mt7925/"
install -m644 "${MT76_SRC}/mt7925/Kbuild" "${DKMS_SRC}/mt76/mt7925/"

# Step 6: DKMS lifecycle
echo "==> DKMS add..."
dkms add "${PKG_NAME}/${PKG_VERSION}"

echo "==> DKMS build (this may take a few minutes)..."
dkms build "${PKG_NAME}/${PKG_VERSION}"

echo "==> DKMS install..."
dkms install "${PKG_NAME}/${PKG_VERSION}"

# Step 7: Post-install
echo "==> Running depmod..."
depmod -a

echo "==> Rebuilding initramfs..."
dracut --force

# Step 8: Attempt to load module
echo "==> Attempting to load mt7925e module..."
# Unload existing mt76 modules first
for mod in mt7925e mt7925_common mt7921e mt7921_common mt792x_lib mt76_connac_lib mt76; do
    modprobe -r "$mod" 2>/dev/null || true
done

if modprobe mt7925e 2>/dev/null; then
    echo "==> mt7925e module loaded successfully"
else
    echo "==> Module load attempted — may need reboot for full initialization"
fi

echo ""
echo "==> WiFi DKMS installation complete."
echo "    DKMS source: ${DKMS_SRC}"
echo "    Module:      ${PKG_NAME}/${PKG_VERSION}"
echo ""
echo "    Next steps:"
echo "      1. Reboot: sudo reboot"
echo "      2. Verify: ./scripts/verify.sh"
