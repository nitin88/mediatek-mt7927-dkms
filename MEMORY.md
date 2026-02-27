# Code Review Memory — mt7927

## Session: 2026-02-27

### Codebase purpose
Fedora 43 wrapper scripts for jetm/mediatek-mt7927-dkms.
Installs a DKMS WiFi+BT module for the MediaTek MT7927 (Filogic 380) chip.
Kernel target: 6.18.x (Fedora 43). mt76 source pinned to 6.19.3.

### Naming conventions
- Scripts: kebab-case (install-wifi.sh, uninstall-firmware.sh)
- Shell vars: UPPER_SNAKE_CASE globals, lower_snake_case locals inside functions
- PKG_NAME / PKG_VERSION used consistently across install/uninstall

### Architectural constraints
- All install scripts require root (EUID check at top)
- set -euo pipefail used everywhere (good)
- DKMS source tree lives at /usr/src/mediatek-mt7927-2.1/
- Firmware lives at /lib/firmware/mediatek/mt7927/
- dkms.conf references PRE_BUILD=dkms-patchmodule.sh which downloads BT source at build time (network required during dkms build)
- mt76 WiFi source is downloaded at install-wifi.sh time (not at dkms build time)
- BT firmware directory uses mt%04x pattern — resolves to mt6639/ not mt7927/ for this chip

### Recurring issues found
1. TMPDIR shadowing: both install-firmware.sh and install-wifi.sh assign to $TMPDIR, which overrides the shell environment variable. Use a different name.
2. Nested function definition (dl_mt76_file inside download_mt76_source) — fine in bash but unusual; can cause issues if function is called outside parent scope after source changes.
3. patch --forward fallback on fuzz: if the first patch -p1 --forward exits non-zero, set -e will NOT be triggered because it's inside `if !`. But the fuzz fallback is NOT inside `if !`, so if the fuzz patch also fails, the script aborts correctly. However, the first failure exit code from patch with --forward on an already-applied patch is 1 (already applied) — this is intentionally tolerated.
4. sort -t. -k4 -n in uninstall-firmware.sh for epoch backup sorting: this is fragile for paths with more dots in the prefix.
5. dkms.conf MAKE[0] drives/bluetooth build but dkms-patchmodule.sh also creates the Makefile — the bt Makefile is a 1-line obj-m assignment, which may be incomplete (no ccflags for out-of-tree headers, no KDIR).
6. BT firmware path mismatch: btmtk.c patch generates path mediatek/mt6639/BT_RAM_CODE... but install-firmware.sh installs firmware to /lib/firmware/mediatek/mt7927/ — these paths diverge.
7. SHA256SUMS written to ${FW_DIR}/SHA256SUMS where FW_DIR is the repo's firmware/ subdir, not /lib/firmware. This is intentional provenance tracking, not a bug, but the variable name is confusing (two different FW_DIR usages).

### Good patterns observed
- Root check via EUID at the top of every privileged script
- Trap-based tmp cleanup in install-firmware.sh and install-wifi.sh
- Explicit per-blob SHA256 verification before installation
- ZIP SHA256 mismatch treated as warning (not fatal) — correct approach since ZIP may be versioned differently
- compgen -G used in uninstall-firmware.sh to check glob expansion before using it (avoids literal glob in ls)
- DKMS idempotency: existing module is removed before re-adding (install-wifi.sh step 4)
- verify.sh uses three independent methods to find the WLAN interface (sysfs driver path, sysfs class/net, ip link)
- No hardcoded secrets anywhere

### Anti-patterns this team tends to introduce
- Using $TMPDIR as a variable name (shadows env)
- Fuzzy patch fallback swallows the real failure reason silently
- cd inside functions without pushd/popd (apply_patches uses cd $srcdir)
