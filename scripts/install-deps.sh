#!/usr/bin/env bash
set -euo pipefail

# Install build dependencies for MT7927 DKMS on Fedora
# Must be run as root

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root (sudo $0)" >&2
    exit 1
fi

if [[ -z "${SUDO_UID:-}" || -z "${SUDO_GID:-}" ||
      ! "${SUDO_UID}" =~ ^[0-9]+$ || ! "${SUDO_GID}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Run this script via sudo from a normal user, not a direct root shell." >&2
    echo "       Example: sudo $0" >&2
    exit 1
fi

KVER="$(uname -r)"

echo "==> Installing build dependencies for kernel ${KVER}..."

dnf install -y \
    dkms \
    "kernel-devel-${KVER}" \
    gcc \
    make \
    curl \
    patch \
    bsdtar \
    python3 \
    unzip \
    bluez \
    usbutils

# Validate kernel-devel matches running kernel
KDEV="/usr/src/kernels/${KVER}"
if [[ ! -d "$KDEV" ]]; then
    echo "ERROR: kernel-devel installed but ${KDEV} not found." >&2
    echo "Available kernel-devel versions:" >&2
    ls /usr/src/kernels/ 2>/dev/null || echo "  (none)" >&2
    echo "" >&2
    echo "You may need to reboot into kernel ${KVER} or install the matching kernel-devel." >&2
    exit 1
fi

echo "==> Dependencies installed. kernel-devel verified at ${KDEV}"
