# agents.md — MT7927 local enablement (Linux)

Goal: make MediaTek MT7927 Wi-Fi usable on our Linux machines with a local, reproducible, rollback-safe workflow.

Status: upstream support is not plug-and-play; treat as experimental DKMS + firmware integration until mainline support exists.

Non-goals: upstreaming to kernel.org, universal distro support, long-term maintenance beyond our kernels.

Assumptions
- Device: PCIe MT7927 confirmed via `lspci` (e.g., `14c3:7927`).
- Symptom: no wlan interface; rfkill shows no Wi-Fi entry; Windows works.
- We accept out-of-tree kernel modules (DKMS) and firmware installation with rollback.

Guardrails
- Pin everything to commits/hashes; no “master HEAD” installs.
- Always keep rollback: bootable older kernel + uninstall scripts.
- Firmware provenance must be recorded and hashed.
- No boot-time USB/xHCI unbind hacks by default; isolate as experimental.

Repository layout (recommended)
- `mt7927/README.md`                    — quickstart, kernel matrix
- `mt7927/agents.md`                    — this file
- `mt7927/dkms/`                        — DKMS packaging, patches, build scripts
- `mt7927/firmware/`                    — firmware blobs + SHA256SUMS + provenance
- `mt7927/scripts/`                     — install/uninstall/verify helpers
- `mt7927/scripts/experimental/`        — optional boot timing workarounds (disabled by default)

Preflight diagnostics (must capture before changes)
- `uname -a`
- `lspci -nnk | sed -n '/Network controller/,+8p'`
- `lsmod | egrep 'mt76|mt79|mt792' || true`
- `dmesg -T | egrep -i 'mt76|mt79|mt792|firmware|wlan|80211' || true`
- `ip link show`
- `rfkill list`

Branching logic
- If `lspci -nnk` shows “Kernel driver in use: (none)” OR mt76 binds but fails init: proceed DKMS+firmware path.
- If device does not enumerate: stop; investigate BIOS/PCIe/IOMMU issues (out of scope here).
- If rfkill is hard-blocked: fix platform RF switch (not our case).

Agents

1) Driver Integrator (DI)
Objective: produce a pinned DKMS build that binds to MT7927 and creates a wlan interface.
Responsibilities:
- Choose baseline approach: patched mt76/mt7925e DKMS method referenced in sources.
- Pin code to a commit hash; vendor patches into `mt7927/dkms/patches/`.
- Provide deterministic build/install:
  - `scripts/install-wifi.sh` (build, install, depmod, initramfs update if needed)
  - `scripts/uninstall-wifi.sh` (remove module, depmod, initramfs restore if needed)
Deliverables:
- `mt7927/dkms/` (dkms.conf + patches + build wrapper)
- Install/uninstall scripts
Acceptance:
- After reboot: `iw dev` lists an interface; `ip link` shows `wlan0` (or similar)
- `dmesg` shows successful probe/bind (no repeated probe failures)

2) Firmware Curator (FW)
Objective: install the exact firmware required by the patched driver with provenance and rollback.
Responsibilities:
- Determine required firmware names from `dmesg` after probe attempt.
- Acquire firmware from pinned/hashes (OEM package or known snapshot).
- Store:
  - `firmware/PROVENANCE.md` (source, version, date)
  - `firmware/SHA256SUMS`
- Implement install with backup:
  - `scripts/install-firmware.sh` (backup existing blobs; copy new; update initramfs if required)
  - `scripts/uninstall-firmware.sh` (restore backup)
Acceptance:
- `dmesg` shows firmware load success (no “not found” / “load failed” loops)

3) Bluetooth Integrator (BT) (optional)
Objective: enable BT only if needed; must not block Wi-Fi.
Responsibilities:
- Keep BT separate from Wi-Fi; no combined “all-in-one” script required.
- If patching btusb/btmtk is needed, pin patch sources and firmware extraction steps.
Deliverables:
- `scripts/install-bt.sh`, `scripts/uninstall-bt.sh` (optional)
Acceptance:
- Controller appears in `bluetoothctl`; no boot regressions

4) Kernel Compatibility Auditor (KCA)
Objective: prevent kernel upgrades from silently breaking connectivity.
Responsibilities:
- Maintain kernel matrix in `README.md`: distro/kernel/board status (PASS/FAIL).
- Add verification script:
  - `scripts/verify.sh` prints PASS/FAIL and reasons:
    - device present
    - module loaded
    - driver bound
    - firmware loaded
    - wlan interface exists
Deliverables:
- Kernel matrix + verify script
Acceptance:
- `verify.sh` produces deterministic failure cause categories (build vs bind vs firmware)

5) Adversarial Reviewer (AR)
Objective: reduce risk of bricking networking / introducing unsafe practices.
Responsibilities (blockers):
- Any unpinned downloads or mutable upstream references.
- Any firmware install without backup/restore.
- Any default-enabled boot hacks (xhci unbind/rebind, initramfs timing hacks).
Deliverables:
- `REVIEW.md` with blocking issues and required fixes.

Iteration workflow (fast but safe)
1) DI: get module to bind and expose wlan interface (even if unstable).
2) FW: make firmware load reliable across reboots.
3) KCA: lock kernel compatibility and add verify/rollback.
4) AR: gate before adopting on daily-driver machines.
5) Optional: BT agent for Bluetooth.

Rollback plan (must always work)
- `scripts/uninstall-all.sh`:
  - remove DKMS modules
  - restore firmware backups
  - rebuild initramfs if modified
- Ensure a known-good kernel remains bootable in bootloader.
- Secure Boot:
  - either sign DKMS modules OR explicitly require SB disabled; do not silently fail.

Quickstart skeleton (what “vibe coding” runs)
- Install Wi-Fi:
  - `sudo ./mt7927/scripts/install-firmware.sh`
  - `sudo ./mt7927/scripts/install-wifi.sh`
  - `sudo reboot`
  - `./mt7927/scripts/verify.sh`
- Uninstall:
  - `sudo ./mt7927/scripts/uninstall-all.sh`
  - `sudo reboot`

Definition of done
- Wi-Fi visible in NetworkManager; scan/connect stable.
- Suspend/resume works OR documented as broken with a non-default workaround.
- Kernel minor update: either continues to work OR fails with clear `verify.sh` output and quick rollback.

Key sources (discussed + used as references)
- Vitalie Miron gist: end-to-end “Wi-Fi via patched mt7925e DKMS + firmware; BT via btusb/btmtk patches; optional timing workaround” (Ubuntu 24.04 + kernel 6.17+). Last active shown on page (Feb 25, 2026).
  - https://gist.github.com/vitaliemiron/c23d7b2e47ab67a7a0851f6ef0cada39  (Feb 25, 2026)  [source for workflow + risks]
- jetm blog: explains why MT7927 support is confusing; explicitly states “no driver yet” as of Feb 20, 2026 (conflicts with later “working” claims; treat as caution).
  - https://jetm.github.io/blog/posts/mt7927-wifi-the-missing-piece/  (Feb 20, 2026)  [source for caution + naming confusion]
- OpenWrt mt76 issue: MT7927 (`14c3:7927`) recognized by mt7925e but fails to initialize (evidence of partial recognition but non-working init in some setups).
  - https://github.com/openwrt/mt76/issues/1022  (Dec 14, 2025)  [source for failure mode]
- Phoronix: Linux 6.19 regression affecting MT792x (revert fixes “dead Wi-Fi” in a dev window). Not MT7927 enablement; interpret as “avoid broken snapshots” and don’t conflate with new support.
  - https://www.phoronix.com/news/Linux-6.19-Fix-MediaTek-WiFi  (Jan 1, 2026)  [source for mt76 regression context]
- Arch forum thread: long-running MT7927 lack-of-support discussion; confirms PCI ID `14c3:7927` and absence of working in-tree support for users.
  - https://bbs.archlinux.org/viewtopic.php?id=303402  (Feb 13, 2025)  [source for historical support gap]
- Kernel wireless docs (MediaTek driver list): reference for what mt76 claims to support; MT7927 not listed (signal that it isn’t standard upstream support).
  - https://wireless.docs.kernel.org/en/latest/en/users/drivers/mediatek.html  (undated)  [source for upstream support signal]

Recent Developments:
- https://github.com/jetm/mediatek-mt7927-dkms
- https://github.com/clemenscodes/linux-mt7927
- https://github.com/NarKarapetyan93/mt7927-bluetooth-linux
- https://github.com/quiloos39/mt76-mt7927-fix
- https://github.com/cmspam/mt7927-nixos
- https://github.com/openwrt/mt76/issues/927