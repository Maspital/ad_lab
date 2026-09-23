# Windows on KVM — spike #11

The decision document for [#11](https://github.com/Maspital/ad_lab/issues/11). It records what
was tried, which versions worked, and what did not. The resulting decisions go to
[decisions.md](decisions.md); this file holds the evidence behind them.

**Status (2026-09-23): in progress.** The spike host is being reinstalled with Ubuntu 26.04 LTS
(see *Spike host*). Done: Q1 desk research, host stack survey, the Q4 harness. Next, in the issue's
order: Q4 on the Linux EFI + swtpm guest (`provisioning/spike/q4-snapshot.sh all`), then Q6, Q2,
Q3, Q1/Q5.

## Spike host

The spike runs on the development laptop (i7-12800H, 20 threads, 32 GB RAM, NVMe), reinstalled
from Ubuntu 24.04 to 26.04 LTS.

**Why not 24.04.** Q4's first candidate needs libvirt ≥ 10.10 (internal snapshots of UEFI
guests with a qcow2 nvram, and revert including the nvram). Ubuntu 24.04 ships libvirt 10.0.0 and
has no supported way to a newer one: the Ubuntu Cloud Archive, which used to backport libvirt and
QEMU to LTS releases, carries neither for noble (checked in the dalmatian, epoxy, flamingo and
gazpacho pockets on 2026-09-23). The in-place upgrade to 26.04 was not yet offered (26.04.1 is
listed with `Supported: 0` in `meta-release-lts`), so the host was reinstalled.

**Distro stacks** (archive versions on 2026-09-23; the preflight entry is written from this
table once Q4 fixes the minimum):

| Release | libvirt | QEMU | swtpm | OVMF (edk2) |
|---|---|---|---|---|
| Ubuntu 24.04 (noble-updates) | 10.0.0 | 8.2.2 | 0.7.3 | 2024.02 |
| Ubuntu 26.04 (resolute-updates) | 12.0.0 | 10.2.1 | 0.10.1 | 2025.11 |
| Debian 13 (trixie) | 11.3.0 | 10.0.13 | 0.7.1 | 2025.02 |

**Firmware files on 26.04.** OVMF moved to `ovmf-generic` (`ovmf` is now a metapackage). It
ships three descriptors in `/usr/share/qemu/firmware/`:

| Descriptor | Code | Vars template | Features |
|---|---|---|---|
| `40-edk2-x86_64-secure-enrolled.json` | `OVMF_CODE_4M.ms.fd` | `OVMF_VARS_4M.ms.fd` | secure-boot, enrolled-keys, requires-smm |
| `50-edk2-x86_64-secure.json` | `OVMF_CODE_4M.secboot.fd` | `OVMF_VARS_4M.fd` | secure-boot, requires-smm |
| `60-edk2-x86_64.json` | `OVMF_CODE_4M.fd` | `OVMF_VARS_4M.fd` | — |

The D19 posture is descriptor 50: `OVMF_CODE_4M.secboot.fd` with the non-enrolled
`OVMF_VARS_4M.fd`, with SMM on. Ubuntu, like Debian and Fedora, ships an enrolled-keys descriptor
that sorts first, so `firmware='efi'` autoselect would enforce Secure Boot here too. All files are
raw; Ubuntu ships no qcow2 firmware builds (relevant if libvirt requires the loader format to
match a qcow2 nvram; the Q4 harness has `LOADER_FORMAT=qcow2` for that case).

### Host setup (after the reinstall)

```sh
sudo apt install libvirt-daemon-system libvirt-clients qemu-system-x86 qemu-utils \
    ovmf swtpm swtpm-tools cloud-image-utils xorriso shellcheck
sudo usermod -aG libvirt,kvm "$USER"          # log out and back in
virsh -c qemu:///system net-autostart default && virsh -c qemu:///system net-start default
```

- **Packer** 1.16.1 from the HashiCorp apt repo (it has a `resolute` suite), QEMU plugin 1.1.6.
- **OpenTofu** 1.12.6. **dmacvicar/libvirt** provider: newest is 0.9.9 (2026-08-30); Q6 picks and
  records the exact pin (D5).
- `libvirt` group membership is the baseline for any unprivileged use of `qemu:///system`; it is
  the starting point of the privilege-model question, not its answer.
- **VirtualBox conflicts with KVM on this kernel.** Since Linux 6.12 KVM enables VT-x when the
  module loads (`kvm.enable_virt_at_load=1`), so VirtualBox VMs cannot start while `kvm_intel` is
  loaded. Do not reinstall VirtualBox on the spike host, or boot with
  `kvm.enable_virt_at_load=0` and accept that the two cannot run at once.

## Q1 — Images

Desk research on 2026-09-23. **Not yet verified in the guest**; Q2 checks each number with
`slmgr /dlv` on the built image.

- **Obtainable media.** The Microsoft Evaluation Center offers Windows Server 2025 (and 2022,
  2016), Windows 11 Enterprise 25H2 and Windows 11 Enterprise LTSC 2024. Every download sits behind a
  registration form. The fwlinks (Server 2025 ISO: `go.microsoft.com/fwlink/?linkid=2268830`)
  redirect to a lead-generation landing page, and the ISO URL is generated per session. **No
  script can fetch the ISOs**, so the operator downloads them by hand and the Packer templates take
  a local path plus SHA-256. That satisfies "no external box registry", but `adlab image build`
  must document the manual step and verify the checksum.
- **Evaluation clock.** Server: 180 days. Windows 11 Enterprise: 90 days.
- **Rearm.** `slmgr /rearm` resets the clock; `slmgr /dlv` shows the remaining time and the
  remaining rearm count; past the limit it fails with `0xC004D307`. Limits are **unverified**:
  earlier Server evals allowed 6 rearms, and one Microsoft Q&A answer claims Server 2025 eval
  allows 1; Windows 11 Enterprise eval reportedly allows 2 (third-party source). On expiry, the
  licence monitor shuts the machine down hourly.
- **Sysprep.** `SkipRearm` (`Microsoft-Windows-Security-SPP`, generalize pass): `0` (default)
  resets licensing state and spends a rearm; `1` leaves it untouched. Microsoft documents that the
  activation grace period starts at the first boot after Setup, but not whether generalize
  restarts an **evaluation** SKU's clock. That is exactly D18's open question, so Q2 measures it:
  build with `SkipRearm=1`, compare `slmgr /dlv` at the end of the Packer build and at an
  instance's first boot.
- **Windows 11 gates.** Microsoft's requirement is "UEFI, Secure Boot capable" plus TPM 2.0.
  Capable-but-off is the documented bar, which matches D19; Q2 confirms it in practice.
- **virtio-win.** The current stable build is 0.1.302-1 (`stable-virtio/virtio-win.iso` redirects
  to `archive-virtio/virtio-win-0.1.302-1/`). Earlier builds (0.1.285) were reported to have
  viostor/vioscsi read errors on Server 2025 under load. Pin an exact version in the template.

## Q2 — Unattended build on libvirt

*Open.*

## Q3 — SSH

*Open.*

## Q4 — Snapshot and revert of golden state

*Open.* The harness `provisioning/spike/q4-snapshot.sh` tests candidate 1 (libvirt internal
snapshot) as the unprivileged user against `qemu:///system`, on an overlay volume, through the
libvirt API only. It plants one marker per layer of golden state (a file on disk, a UEFI variable,
a TPM NV index), takes golden, changes all three, reverts, and reads which markers came back. It
does this live (memory included) and on a stopped VM, and records snapshot/revert time, overlay
growth, `<genid/>` before and after, and guest clock skew before and after qemu-ga
`guest-set-time`. Results are appended to `~/.local/state/adlab-spike/q4/results.md` and folded
in here. Run it once per guest RAM size (`RAM_MB=1024|2048|4096`) to measure how overlay growth
scales with RAM.

## Q5 — Sizing and timing

*Open.*

## Q6 — OpenTofu fit

*Open.*
