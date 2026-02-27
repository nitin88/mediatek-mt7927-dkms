#!/usr/bin/env bash
set -euo pipefail

# MT7927 Bluetooth verification script

PASS=0
FAIL=0
WARN=0

pass() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1 ($2)"; FAIL=$((FAIL + 1)); }
warn() { echo "  [WARN] $1"; WARN=$((WARN + 1)); }
info() { echo "  [INFO] $1"; }

FW_FILE="/lib/firmware/mediatek/mt6639/BT_RAM_CODE_MT6639_2_1_hdr.bin"
FW_SHA256="27c6a38598176e3dde7baa87d0749aec12013db29cbaec97db14079abce5079f"

echo "========================================"
echo " MT7927 Bluetooth Verification"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo " Kernel: $(uname -r)"
echo "========================================"
echo ""

echo "--- Check 1: USB Bluetooth device present ---"
if command -v lsusb >/dev/null 2>&1; then
    if lsusb | grep -qiE '0489:e13a|0489:e110|0489:e0fa|0489:e116|13d3:3588'; then
        pass "MT7927/MT6639 Bluetooth USB device detected"
        lsusb | grep -iE '0489:e13a|0489:e110|0489:e0fa|0489:e116|13d3:3588' | sed 's/^/         /'
    else
        warn "Known MT7927 BT USB IDs not found (may still use another ID)"
    fi
else
    warn "lsusb not available - skipping USB ID check"
fi
echo ""

echo "--- Check 2: BT firmware present ---"
if [[ -f "${FW_FILE}" ]]; then
    ACTUAL_SHA="$(sha256sum "${FW_FILE}" | awk '{print $1}')"
    if [[ "${ACTUAL_SHA}" == "${FW_SHA256}" ]]; then
        pass "BT firmware present and hash matches"
    else
        fail "BT firmware hash mismatch" "firmware"
        echo "         Expected: ${FW_SHA256}"
        echo "         Actual:   ${ACTUAL_SHA}"
    fi
    ls -l "${FW_FILE}" | sed 's/^/         /'
else
    fail "BT firmware file missing: ${FW_FILE}" "firmware"
fi
echo ""

echo "--- Check 3: BT modules loaded ---"
LSMOD_ALL="$(lsmod 2>/dev/null || true)"
if echo "${LSMOD_ALL}" | grep -q '^btusb'; then
    pass "btusb module loaded"
else
    fail "btusb module not loaded" "module"
fi

if echo "${LSMOD_ALL}" | grep -q '^btmtk'; then
    pass "btmtk module loaded"
else
    warn "btmtk module not loaded"
fi
echo ""

echo "--- Check 4: BT driver binding ---"
DMESG_BT="$(dmesg 2>/dev/null | grep -iE 'btusb|btmtk|hci0|mediatek' | tail -20 || true)"
if [[ -n "${DMESG_BT}" ]]; then
    if echo "${DMESG_BT}" | grep -qiE 'failed|error|timeout'; then
        warn "Potential BT errors in dmesg"
        echo "${DMESG_BT}" | sed 's/^/         /'
    else
        pass "No obvious BT errors in recent dmesg lines"
    fi
else
    info "No BT dmesg lines captured (may need root)"
fi
echo ""

echo "--- Check 5: Controller visibility ---"
if command -v bluetoothctl >/dev/null 2>&1; then
    # Non-interactive bluetoothctl often needs stdin commands in pipe mode.
    BT_LIST="$(printf 'list\nquit\n' | bluetoothctl 2>/dev/null | grep 'Controller' || true)"
    if [[ "${BT_LIST}" == *Controller* ]]; then
        pass "Bluetooth controller visible"
        echo "${BT_LIST}" | sed 's/^/         /'
    else
        fail "No Bluetooth controller visible in bluetoothctl" "runtime"
        echo "         Run: systemctl status bluetooth"
    fi
else
    warn "bluetoothctl not available - skipping controller visibility check"
fi
echo ""

echo "--- Check 6: DKMS status ---"
DKMS_STATUS="$(dkms status mediatek-mt7927-bt/1.0 2>/dev/null || true)"
if [[ -n "${DKMS_STATUS}" ]]; then
    if [[ "${DKMS_STATUS}" == *installed* ]]; then
        pass "DKMS BT module installed"
    else
        warn "DKMS BT status: ${DKMS_STATUS}"
    fi
    echo "         ${DKMS_STATUS}"
else
    fail "DKMS BT module mediatek-mt7927-bt/1.0 not registered" "build"
    echo "         Run: sudo ./scripts/install-bt.sh"
fi
echo ""

echo "========================================"
echo " Summary: ${PASS} PASS, ${FAIL} FAIL, ${WARN} WARN"
echo "========================================"

if [[ ${FAIL} -eq 0 ]]; then
    echo " Status: ALL CHECKS PASSED"
    exit 0
else
    echo " Status: ${FAIL} CHECK(S) FAILED"
    exit 1
fi
