# ADR-047: Surface Pro 4 boot-slot ownership and linux-surface kernel pinning

**Status:** Accepted
**Date:** 2026-10-12
**Supersedes:** —
**Related:** H2-210 (migrate homelab-one into k3s), H2-217 (retire Surface Pro 4),
[ADR-046](adr-046-zigbee-namespace-storage-model.md) (zigbee namespace storage model)

## Context

`homelab-one` — a **Microsoft Surface Pro 4** — spent its life as the home-automation appliance
(`temp_collector`: zigbee2mqtt → Mosquitto → Node-RED → InfluxDB → Grafana, plus Flame). With that
stack migrated into k3s, the box is being repurposed as a **normal personal tablet**.

Out of the box it is a poor tablet: the stock Pop!_OS kernel knows nothing about the Surface's
embedded controller, so there is no touchscreen, no pen, and no sensible power management. The
**linux-surface** project ships the patched kernel + userspace that fixes this.

The catch is *not* installing linux-surface — it is **making it boot, and keeping it booting**.

Two facts about Pop!_OS 24.04 make that non-obvious:

1. Pop!_OS does not use GRUB. It boots by **EFI stub**: `kernelstub` copies a kernel into the ESP
   (`/boot/efi/EFI/Pop_OS-<uuid>/vmlinuz.efi`) and rewrites the systemd-boot entry
   `Pop_OS-current.conf` to point at that copy.
2. `/etc/kernel/postinst.d/zz-kernelstub` — the hook that runs on **every** kernel install — derives
   the new kernel's paths and then **never passes them**:

   ```bash
   #!/bin/bash
   INITRD="/boot/initrd.img-$1"
   KERNEL="$2"
   kernelstub --verbose --preserve-live-mode    # <-- $KERNEL / $INITRD never used
   ```

   A bare `kernelstub` re-applies its stored config, which follows `/boot/vmlinuz` → the newest
   **distribution** kernel.

Observed consequence in this lab: `linux-image-surface` had been installed since **December 2025**,
and the machine had booted Pop's kernel on every single boot since. The surface kernel's initrd was
built, sat in `/boot`, and was referenced by no boot entry at all. `uname -r` never once contained
`surface`.

Upstream knows this class of problem: Fedora ships a `linux-surface-default-watchdog` precisely
because *"if the default kernel has a higher version than the surface kernel it will override the
surface kernel and get booted by default"*. Nothing equivalent exists for Pop!_OS.

## Decision

**Pop!_OS keeps ownership of its bootloader; we pin its boot slot to the newest installed
linux-surface kernel, and we defend that pin with dpkg rather than with a watcher.**

Concretely:

- linux-surface is installed from the upstream Debian/Ubuntu repo with the full userspace set:
  `linux-image-surface`, `linux-headers-surface`, `libwacom-surface`, `iptsd`,
  `linux-surface-secureboot-mok`.
- The boot slot is pointed at the surface kernel **using Pop's own tool**:
  `kernelstub -k /boot/vmlinuz-<surface> -i /boot/initrd.img-<surface>`. This keeps a Pop-kernel
  fallback (`vmlinuz-previous.efi`) and leaves every other ESP entry intact.
- A root-owned `/usr/local/sbin/surface-kernel-pin` re-asserts that pin, invoked from
  `/etc/apt/apt.conf.d/99pin-surface-kernel` via `DPkg::Post-Invoke`.
  **dpkg, not systemd**: `Post-Invoke` runs strictly *after* `zz-kernelstub` has finished, so there is
  no race and the pin deterministically wins. The script is idempotent — it `cmp`s the ESP copy
  against the surface kernel and exits silently when they already match.
- `loader.conf` gets a `timeout 3`, so a kernel that fails to boot is recoverable from the boot menu
  instead of leaving a dead tablet with no way in.
- The distro hook is **left untouched**. It is a Pop!_OS bug, and patching a distribution-owned file
  is a maintenance liability that the next `pop-desktop` upgrade silently reverts.

## Consequences

**Positive**

- The Surface boots the kernel it was supposed to boot all along: `6.19.8-surface-3`, proven by
  `uname -r` after a real reboot.
- Touch, pen, the Surface button driver and the aggregator stack all come up —
  `IPTSD Virtual Touchscreen`, `IPTSD Virtual Stylus`, `surface_pro3_button`.
- A Pop!_OS kernel update can no longer silently steal the boot slot — the exact failure that made
  the December 2025 install a no-op.
- The fix survives a linux-surface kernel *upgrade* too: the new kernel installs, the distro hook
  points the slot back at Pop, `Post-Invoke` re-pins to the new surface kernel. One mechanism covers
  both directions.
- A working Pop kernel stays installed as a fallback (`Pop_OS-oldkern.conf`, with the previous ESP
  kernel preserved as `vmlinuz-previous.efi`).

**Negative / accepted costs**

- A 3-second boot menu on every startup. Deliberate: it is the recovery path for a kernel that does
  not boot, and this box has no remote console (the JetKVM is not attached to it).
- A hand-maintained script on an otherwise unmanaged device. It is invisible when it works: it exits
  0 with no output when the pin is already correct.
- Pop!_OS still *believes* the Pop kernel is current — `kernelstub -p` reports the Pop kernel. That
  is cosmetic and expected; the ESP copy is the truth.
- Secure Boot stays disabled (platform is in Setup Mode). The MOK package is installed for the day
  that changes, but it does nothing today.
- `apt-mark hold` on the Pop kernel was **not** used, so Pop kernel security updates keep flowing as
  a fresh fallback. The trade is that every such update will "steal" the slot and then be re-pinned.

## Alternatives considered

1. **`apt-mark hold` on the Pop kernel packages** — stops the distro kernel taking the slot by
   stopping it updating at all. Rejected: it silently freezes kernel security updates for the
   fallback and leaves permanently held-back packages that read as a broken apt to the next person.
2. **Fix `/etc/kernel/postinst.d/zz-kernelstub` in place** — the one-line fix that hook is clearly
   asking for. Rejected: it is a distribution-owned file, the next `kernelstub`/`pop-desktop` upgrade
   reverts it silently, and we would be back to a dead tablet with no trace of why. It also would not
   have solved our problem — passing the *Pop* kernel still points the slot at the Pop kernel.
3. **A separate systemd-boot entry** (`linux-surface.conf`, with vmlinuz+initrd copied into their own
   ESP directory, selected via `loader.conf`) — rejected after checking behaviour: `kernelstub`
   rewrites `loader.conf`'s `default` on every run, so the extra entry would be permanently
   de-selected. It also duplicates ~150 MB in a 1 GB ESP that `kernelstub` already wants for its own
   copies.
4. **A systemd path unit watching `/boot`** (the Fedora precedent) — rejected: it fires *concurrently*
   with the kernel postinst hooks, so pin and hook race; `DPkg::Post-Invoke` is ordered after them by
   construction. `/boot/efi` also sits under the watched tree, making the trigger noisier than it
   needs to be.
5. **Do nothing; document that the kernel must be re-pointed by hand after every Pop kernel update** —
   rejected: that is precisely the silent failure that left the box without touch for ten months. A
   documented manual step is not a mechanism.

## When to revisit

- Pop!_OS fixes `zz-kernelstub` to pass `-k`/`-i` — the pin script becomes redundant defensive code
  and can be dropped (or kept; it costs one `cmp` per dpkg transaction).
- Pop!_OS replaces `kernelstub` (adopts `kernel-install`/BLS properly, or ships unified kernel
  images) — the ESP model changes and this ADR is obsolete.
- The device stops being a Pop!_OS tablet (reinstall, different distro): the pin script, the apt hook
  and the 3 s timeout all go with the OS.
- The Surface is retired entirely.
