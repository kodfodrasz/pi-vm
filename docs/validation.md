# Validation notes

Tested on 8 October 2026 (UTC), on this Linux host inside Hyper-V.
The host exposes AMD-V and `/dev/kvm`; the host KVM nested setting is on.

## Results

| Check | Result |
| --- | --- |
| Fedora 44-1.7 compressed raw image SHA-256 | Pass |
| Expanded 5 GiB raw image size and SHA-256 | Pass |
| Raw image with NoCloud ISO on KVM, BIOS boot | Pass |
| Raw image with NoCloud ISO on KVM, UEFI boot | Pass, OVMF test |
| Fresh 1 CPU / 1024 MiB / 8 GiB guest bootstrap | Pass |
| Default 2 CPU / 2048 MiB / 16 GiB guest bootstrap | Pass |
| Root partition and filesystem fill the disk | Pass, about 7.9 GiB and 16 GiB roots |
| `pi` user, fish login, hostname `pipette` | Pass |
| Pi 1.1.0, Starship 1.26.0 | Pass |
| Initial public-key login and password login off | Pass |
| SELinux enforcing | Pass |
| Rootless Podman info and user namespace | Pass |
| Vim, tmux, fish config and Pi completion loading | Pass |
| No guest QEMU or libvirt packages | Pass |
| Virtio balloon: 1 GiB to 768 MiB, then restored | Pass, QMP queried actual size |
| Nested KVM executes an L2 halt instruction | Pass, Python KVM ioctl test |
| Graceful stop and restart preserve the disk | Pass |
| Below-source KVM disk size rejected before instance creation | Pass |
| Seed ISO label and root files | Pass, `CIDATA`, `user-data`, `meta-data` |
| PowerShell syntax and ISO C# stream helper compilation | Pass on Linux |
| Fixed VHD footer, QEMU recognition, raw/VHD content match | Pass, small and 5 GiB cases |
| Windows IMAPI2FS ISO creation | Not tested; needs Windows |
| Windows 11 Hyper-V base/child creation and deployment | Not tested; needs Windows |
| Hyper-V memory reclamation inside the new guest | Not tested; needs Windows |

The first boot may show `extended_status: degraded done` with recoverable hostname
warnings. Fedora cloud-init tries `hostnamectl` before the system bus exists.
Bootstrap sets the hostname later, the schema passes, and `errors` is empty.
After a normal restart, the deployed guest reports `extended_status: done`, no
errors, and no recoverable warnings. Do not ignore other warnings or missing
bootstrap markers.

## Current deployment

`pipette` is running with 2 CPUs, 2048 MiB RAM, and a 16 GiB disk.
Only this project's deployed VM was left running. The small test guests are
stopped; their disks and logs remain in `build/`. External raw/UEFI probe files
remain in `~/.cache/pi-vm/probe/`, with that probe stopped.

```sh
ssh -p 2222 pi@127.0.0.1
make kvm-status INSTANCE=pipette
make kvm-stop INSTANCE=pipette
make kvm-start INSTANCE=pipette
```

The runtime checks used a private test known-hosts file at
`~/.cache/pi-vm/host/pipette-known-hosts`. If you have an old key for port 2222,
use that file explicitly rather than disabling SSH host-key checks:

```sh
ssh -o UserKnownHostsFile="$HOME/.cache/pi-vm/host/pipette-known-hosts" \
    -p 2222 pi@127.0.0.1
```

Main logs are `build/host-tests.log`, `build/final-runtime.log`,
`build/pipette-runtime.log`, and each VM's `serial.log`/`qemu.log`.
The clean post-restart status is in `~/.cache/pi-vm/host/pipette-reboot.log`.
These local logs are not tracked by Git.

## Repeat the tests

Run `make test`. Large test scratch files use `build/test-tmp`, not `/tmp`.
The optional 5 GiB VHD test needs about 11 GiB free. Do not report it as passed
if it was skipped for missing tools or space.

For a fresh guest test, use a new instance ID and an unused SSH port:

```sh
./scripts/kvm.sh start check-001 --cpus 1 --memory 1024 --disk 8G --ssh-port 2223
ssh -p 2223 pi@127.0.0.1
# Inside the guest:
sudo cloud-init status --long
sudo cloud-init schema --system
test -f /var/lib/pi-vm/bootstrap-complete
```

To test actual nested KVM without guest QEMU packages, run from the host:

```sh
ssh -p 2223 pi@127.0.0.1 'sudo modprobe kvm_amd; sudo python3 -' \
    < tests/nested-kvm.py
```

Use `kvm_intel` instead of `kvm_amd` on an Intel host. The test maps one page,
creates an L2 VM and VCPU through `/dev/kvm`, runs a halt instruction, and checks
for `KVM_EXIT_HLT`. A CPU flag alone is not accepted as proof of nested execution.

The reusable Pi skill is `.agents/skills/validate-pi-vm/SKILL.md`. It covers
storage limits, fresh boot tests, balloon checks, shutdown, and Windows caveats.

## Review

Luna agents handled local scouting and bounded coding work. A Terra reviewer
found the initial Hyper-V temporary-file extension and minimum-size issues.
Those were fixed. The recheck returned **OK with notes**, with no remaining P1
blocker. Its outdated disk-unit documentation note is fixed. Its seed-failure
note is also fixed: new KVM instances now build the ISO before the overlay,
and seed publication is atomic. Tests were rerun afterward.

A first reviewer process failed before returning a result. It was retried
through the same subagent system; that failed run was not counted as a review.
