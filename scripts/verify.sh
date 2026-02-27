#!/usr/bin/env bash
set -euo pipefail

# MT7927 WiFi verification script
# Runs diagnostic checks and reports PASS/FAIL per category
# Can be run as regular user (some checks need root for full detail)
#
# NOTE: grep -q is avoided in pipelines under pipefail because grep -q
# closes stdin early, causing SIGPIPE (exit 141) on the upstream command.
# Instead, capture output into variables first, then test with [[ ]].

# Known PCI IDs for MT7927/MT6639
PCI_IDS=("14c3:7927" "14c3:6639" "14c3:0738")

PASS=0
FAIL=0
WARN=0

pass() { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1 ($2)"; FAIL=$((FAIL + 1)); }
warn() { echo "  [WARN] $1"; WARN=$((WARN + 1)); }
info() { echo "  [INFO] $1"; }

echo "========================================"
echo " MT7927 WiFi Verification"
echo " $(date '+%Y-%m-%d %H:%M:%S')"
echo " Kernel: $(uname -r)"
echo "========================================"
echo ""

# --- Preflight diagnostics ---
echo "--- System Info ---"
info "$(uname -a)"
echo ""

# Capture state once upfront to avoid grep -q SIGPIPE issues under pipefail
LSPCI_ALL="$(lspci 2>/dev/null || true)"
LSMOD_ALL="$(lsmod 2>/dev/null || true)"

# --- Check 1: Device present (hardware) ---
echo "--- Check 1: Device present ---"
DEVICE_FOUND=""
for pci_id in "${PCI_IDS[@]}"; do
    LSPCI_DEV="$(lspci -d "$pci_id" 2>/dev/null || true)"
    if [[ -n "$LSPCI_DEV" ]]; then
        DEVICE_FOUND="$pci_id"
        pass "MT7927 device found (PCI ID: ${pci_id})"
        lspci -d "$pci_id" -v 2>/dev/null | head -5 | sed 's/^/         /'
        break
    fi
done
if [[ -z "$DEVICE_FOUND" ]]; then
    if echo "$LSPCI_ALL" | grep -qi 'MT7927\|MT6639\|Filogic 380'; then
        DEVICE_FOUND="by-name"
        pass "MT7927 device found (by name)"
    else
        fail "MT7927 device not found" "hardware"
        echo "         Checked PCI IDs: ${PCI_IDS[*]}"
        echo "         Run: lspci | grep -i mediatek"
    fi
fi
echo ""

# --- Check 2: Module loaded (build) ---
echo "--- Check 2: Module loaded ---"
if echo "$LSMOD_ALL" | grep -q 'mt7925e'; then
    pass "mt7925e module loaded"
    echo "$LSMOD_ALL" | grep -E 'mt7925|mt792x|mt76' | sed 's/^/         /'
elif echo "$LSMOD_ALL" | grep -q 'mt76'; then
    warn "mt76 loaded but mt7925e not loaded"
    echo "$LSMOD_ALL" | grep 'mt76' | sed 's/^/         /'
else
    fail "mt7925e module not loaded" "build"
    echo "         Run: modprobe mt7925e"
    echo "         Check: dkms status mediatek-mt7927/2.1"
fi
echo ""

# --- Check 3: Driver bound (bind) ---
echo "--- Check 3: Driver bound ---"
DRIVER_BOUND=""
for pci_id in "${PCI_IDS[@]}"; do
    DRIVER_LINE="$(lspci -nnk -d "$pci_id" 2>/dev/null | grep 'Kernel driver in use' || true)"
    if [[ -n "$DRIVER_LINE" ]]; then
        DRIVER_BOUND="$DRIVER_LINE"
        if [[ "$DRIVER_LINE" == *mt7925e* ]]; then
            pass "Driver mt7925e bound to device"
        else
            warn "Different driver bound: ${DRIVER_LINE}"
        fi
        break
    fi
done
if [[ -z "$DRIVER_BOUND" ]]; then
    if [[ -n "$DEVICE_FOUND" ]]; then
        fail "No driver bound to MT7927 device" "bind"
        echo "         The device is present but no kernel driver is attached."
    else
        info "Skipped (device not present)"
    fi
fi
echo ""

# --- Check 4: Firmware loaded (firmware) ---
echo "--- Check 4: Firmware loaded ---"
FW_DIR="/lib/firmware/mediatek/mt7927"
if [[ -d "$FW_DIR" ]]; then
    FW_COUNT="$(find "$FW_DIR" -name '*.bin' -type f 2>/dev/null | wc -l)"
    if [[ "$FW_COUNT" -ge 2 ]]; then
        pass "WiFi firmware files present (${FW_COUNT} blobs in ${FW_DIR})"
        ls -la "$FW_DIR"/*.bin 2>/dev/null | sed 's/^/         /'
    else
        fail "WiFi firmware incomplete (${FW_COUNT} blobs, expected >= 2)" "firmware"
    fi
else
    fail "Firmware directory ${FW_DIR} does not exist" "firmware"
    echo "         Run: sudo ./scripts/install-firmware.sh"
fi

# Check dmesg for firmware load status (needs root or readable dmesg)
DMESG_FW="$(dmesg 2>/dev/null | grep -iE 'mt7927|mt7925|mt6639' | grep -iE 'firmware' | tail -5 || true)"
if [[ -n "$DMESG_FW" ]]; then
    if [[ "$DMESG_FW" == *[Ff]ail* || "$DMESG_FW" == *[Ee]rror* || "$DMESG_FW" == *"not found"* ]]; then
        fail "Firmware load errors in dmesg" "firmware"
        echo "$DMESG_FW" | sed 's/^/         /'
    else
        pass "No firmware errors in dmesg"
    fi
else
    info "No firmware-related dmesg entries (may need root)"
fi
echo ""

# --- Check 5: WLAN interface exists (bind) ---
echo "--- Check 5: WLAN interface exists ---"
WLAN_IFACE=""

# Method 1: Find interface bound to mt7925e via sysfs
for dev_path in /sys/bus/pci/drivers/mt7925e/*/net/*; do
    if [[ -d "$dev_path" ]]; then
        WLAN_IFACE="$(basename "$dev_path")"
        break
    fi
done

# Method 2: Check /sys/class/net/*/device/driver
if [[ -z "$WLAN_IFACE" ]]; then
    for net in /sys/class/net/*; do
        local_driver="${net}/device/driver"
        if [[ -L "$local_driver" ]]; then
            driver_name="$(basename "$(readlink "$local_driver")")"
            if [[ "$driver_name" == "mt7925e" ]]; then
                WLAN_IFACE="$(basename "$net")"
                break
            fi
        fi
    done
fi

# Method 3: Any wlan/wlp interface
if [[ -z "$WLAN_IFACE" ]]; then
    WLAN_IFACE="$(ip -o link show 2>/dev/null | grep -oE 'wl[a-z0-9]+' | head -1 || true)"
fi

if [[ -n "$WLAN_IFACE" ]]; then
    pass "WLAN interface found: ${WLAN_IFACE}"
    ip link show "$WLAN_IFACE" 2>/dev/null | sed 's/^/         /'
else
    fail "No WLAN interface found" "bind"
    echo "         Expected: wlan0 or wlpXsY"
fi
echo ""

# --- Check 6: DKMS status ---
echo "--- Check 6: DKMS status ---"
DKMS_STATUS="$(dkms status mediatek-mt7927/2.1 2>/dev/null || true)"
if [[ -n "$DKMS_STATUS" ]]; then
    if [[ "$DKMS_STATUS" == *installed* ]]; then
        pass "DKMS module installed"
    elif [[ "$DKMS_STATUS" == *built* ]]; then
        warn "DKMS module built but not installed"
    else
        warn "DKMS module status: ${DKMS_STATUS}"
    fi
    echo "         ${DKMS_STATUS}"
else
    fail "DKMS module mediatek-mt7927/2.1 not registered" "build"
    echo "         Run: sudo ./scripts/install-wifi.sh"
fi
echo ""

# --- Check 7: rfkill ---
echo "--- Check 7: RF kill status ---"
RFKILL="$(rfkill list 2>/dev/null | grep -A3 -Ei 'wlan|wifi|wireless lan' || true)"
if [[ -n "$RFKILL" ]]; then
    if [[ "$RFKILL" == *"Hard blocked: yes"* ]]; then
        fail "WiFi hard-blocked by rfkill" "hardware"
    elif [[ "$RFKILL" == *"Soft blocked: yes"* ]]; then
        warn "WiFi soft-blocked (run: rfkill unblock wifi)"
    else
        pass "WiFi not blocked by rfkill"
    fi
    echo "$RFKILL" | sed 's/^/         /'
else
    info "No WiFi device in rfkill list"
fi
echo ""

# --- Check 8: Secure Boot compatibility ---
echo "--- Check 8: Secure Boot compatibility ---"
if command -v mokutil >/dev/null 2>&1; then
    SB_STATE="$(mokutil --sb-state 2>/dev/null || true)"
    if [[ "$SB_STATE" == *"SecureBoot enabled"* ]]; then
        warn "Secure Boot enabled - unsigned DKMS modules may fail to load"
        echo "         Disable Secure Boot or sign DKMS modules for reliable loading."
    elif [[ "$SB_STATE" == *"SecureBoot disabled"* ]]; then
        pass "Secure Boot disabled (compatible with unsigned DKMS modules)"
    else
        warn "Unable to determine Secure Boot state via mokutil"
        if [[ -n "$SB_STATE" ]]; then
            echo "         ${SB_STATE}"
        fi
    fi
else
    warn "mokutil not installed - cannot verify Secure Boot state"
fi
echo ""

# --- Summary ---
echo "========================================"
echo " Summary: ${PASS} PASS, ${FAIL} FAIL, ${WARN} WARN"
echo "========================================"

if [[ $FAIL -eq 0 ]]; then
    echo " Status: ALL CHECKS PASSED"
    exit 0
else
    echo " Status: ${FAIL} CHECK(S) FAILED"
    echo ""
    echo " Troubleshooting order:"
    echo "   1. hardware — check BIOS/PCIe, run: lspci | grep -i mediatek"
    echo "   2. firmware — run: sudo ./scripts/install-firmware.sh"
    echo "   3. build    — run: sudo ./scripts/install-wifi.sh"
    echo "   4. bind     — reboot, then re-run this script"
    exit 1
fi
