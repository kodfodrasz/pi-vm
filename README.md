# pi-vm

Build a clean Fedora 44 x86-64 VM for Pi. The default hostname is `pipette`.
The user is `pi`, with fish as its login shell.

## Guest setup

The guest includes:

- Pi **1.1.0**, Node.js, npm, Git, ripgrep, and fd.
- Vim, micro, tmux, fish, fastfetch, and Starship **1.26.0**.
- Podman, Python, make, GCC, curl, jq, rsync, and unzip.
- Fedora kernel balloon drivers and Hyper-V guest services.

Vim, tmux, and Starship settings come from this host. Fish uses a small,
portable config and completions checked against Pi 1.1.0. Starship is a pinned,
checksummed upstream binary because Fedora 44 has no Starship package.

No QEMU, libvirt, or KVM tools are installed in the guest. The kernel can still
support nested KVM. SELinux stays enforcing. Rootless Podman has user ID ranges
and user linger enabled.

SSH uses the public keys in `assets/authorized_keys`. These are the combined
keys from the original user's authorized keys and public key files. Their IDs
and fingerprints are in `assets/public-key-identities.txt`. No private keys,
Pi credentials, or session history are copied. Password login is off. The `pi`
user has password-free sudo. **Anyone holding one of these keys can become root.**
Review the public keys before sharing or deploying this project.

## Linux / KVM

You need x86-64 Linux with working `/dev/kvm`. A parent hypervisor must expose
CPU virtualization if this host is itself a VM. Install the host tools on Fedora:

```sh
sudo dnf install qemu-system-x86-core qemu-img xorriso curl xz python3 util-linux
```

Start a normal VM:

```sh
make test
make kvm-start INSTANCE=pipette
make kvm-status INSTANCE=pipette
ssh -p 2222 pi@127.0.0.1
```

Use a small test VM:

```sh
make kvm-start INSTANCE=my-test MEMORY=1024 CPUS=1 DISK=8G SSH_PORT=2223
ssh -p 2223 pi@127.0.0.1
```

Defaults: 2 CPUs, 2048 MiB RAM, 16 GiB disk, and loopback SSH port 2222.
Different running VMs need different SSH ports. Disks must be at least 5 GiB;
8 GiB or more gives room for the software and root growth.

The scripts download and check the Fedora raw image, convert it to a shared
qcow2 base, and create a qcow2 overlay for each VM. A `cidata` ISO supplies
cloud-init. The root partition and filesystem grow to fill the guest disk.
QEMU runs with KVM acceleration, the host CPU, and a virtio balloon device.
The scripts do not change host networking or kernel settings.

Stop and restart without losing the disk:

```sh
make kvm-stop INSTANCE=my-test
make kvm-status INSTANCE=my-test  # exits nonzero when stopped
make kvm-start INSTANCE=my-test MEMORY=1024 CPUS=1 DISK=8G SSH_PORT=2223
```

Stop sends an ACPI power button request. Wait for the VM to stop before restarting.
`./scripts/kvm.sh stop my-test --force` terminates QEMU if the guest is stuck.
**`start ID --force` deletes that stopped instance and creates a new disk.**
An active instance cannot be rebuilt. Resource flags apply when starting QEMU;
`--disk` only sets the size of a new disk.

### First boot and logs

First boot needs internet access for Fedora packages, npm, and Starship. Wait
about two minutes on a fast link; slower links may take longer. SSH works before
all software is ready. Check these inside the VM:

```sh
sudo cloud-init status --long
sudo cloud-init schema --system
test -f /var/lib/pi-vm/bootstrap-complete
sudo tail -60 /var/log/cloud-init-output.log
pi --version
podman info --format '{{.Host.Security.Rootless}}'
```

The bootstrap success marker is written only after the full install succeeds. Cloud-init does
not rerun the entire install on every reboot. The same ISO and instance ID stay
with each disk. Fedora's first boot may report recoverable early hostname
warnings; bootstrap sets the name later. Check the marker and `errors` field.
The tested guest had clean cloud-init status after its first normal restart. If a new test VM reuses an SSH port, use a separate SSH known-hosts
file. Do not blindly disable host-key checks on a reused port.

Host logs are `build/ID/serial.log` and `build/ID/qemu.log`. VM control uses a
local QMP socket in the same directory. Treat your build directory as private.

### Storage

Downloaded images stay in `~/.cache/pi-vm/images`. VM disks, ISOs, logs, and test
scratch files stay in `build/`, **not `/tmp`**. Set `PI_VM_CACHE` and `PI_VM_BUILD`
to absolute paths on a larger disk if needed. Keep at least 10 GiB free for a
Linux download and a small guest. Sparse disks can grow, so watch host free space.
The VHD conversion test needs about 11 GiB of free disk space.

Do not edit, move, or delete a shared base while any child disk depends on it.
The scripts never boot the base itself. To build only a seed ISO:

```sh
make seed INSTANCE=another-pi
# Output: build/another-pi-seed.iso
```

## Windows 11 / Hyper-V

Run PowerShell as Administrator. You need the Hyper-V feature and module,
Python available as `python`, and 7-Zip available as `7z.exe`. Keep at least
20 GiB free on the build/cache disk for raw and fixed-VHD conversion files.
Use local disk storage, not a temporary or cloud-sync folder.

```powershell
.\scripts\hyperv.ps1 -Action start -Id pipette
.\scripts\hyperv.ps1 -Action status -Id pipette
.\scripts\hyperv.ps1 -Action stop -Id pipette
```

The script downloads and checks the same raw image. It writes a fixed VHD,
uses native `Convert-VHD` to make a VHDX base, grows that base, and creates a
**differencing VHDX** for each VM. A separate immutable base is used for each
disk size. No Windows `qemu-img` is needed.

Without `-SeedIso`, `seed.ps1` uses Python and Windows IMAPI2FS to build a real
`cidata` ISO with `user-data` and `meta-data`. The ISO stays at
`build/seeds/ID.iso`. You can instead supply an ISO made on Linux:

```powershell
.\scripts\hyperv.ps1 -Action start -Id my-test -SeedIso C:\images\my-test.iso `
    -MemoryMB 1024 -CpuCount 1 -DiskSize 8GiB
```

Defaults: hostname `pipette`, Generation 2, 2 CPUs, 2048 MiB static RAM,
16 GiB disk, and the existing `Default Switch`. Secure Boot is off. Nested
virtualization extensions are exposed. The script does not create switches.
Use `-Switch`, `-Cache`, `-Build`, or `-Hostname` to change those settings.
Disk sizes must be at least 5 GiB and aligned to 1 MiB. Use values such as
`8GiB` or `16GiB`. `-DynamicMemory` is an opt-in option; static RAM is safer
for nested virtualization.

Starting an existing stopped VM preserves its disk and settings. To rebuild,
remove the old VM explicitly, then use `-Force` to replace its instance files.
Generated seed ISOs are reused: remove `build/seeds/ID.iso` explicitly if you
want new bootstrap settings for a **new disk**. Changing an ISO does not rerun
cloud-init on an old disk. Open the console with `vmconnect.exe localhost pi-vm-pipette`.

**Windows IMAPI2FS and actual Hyper-V deployment still need manual testing.**
PowerShell syntax, the C# stream helper, and VHD disk format/content were checked
on Linux. Those checks are not a Windows deployment test.

## Checks and repeatability

`make test` checks shell syntax, seed keys and embedded files, fish syntax when
available, PowerShell parsing and C# compilation when available, and VHD footer
fields/content with `pwsh` and `qemu-img`. It downloads nothing and boots no VM.
The 5 GiB VHD test runs only when enough disk space is available.

`tests/nested-kvm.py` runs a tiny L2 guest inside a test VM. It needs root and
the stock KVM kernel module, not a QEMU package. See `docs/validation.md` for
runtime test results and commands.

The source is Fedora Cloud Base AmazonEC2 **44-1.7** from Fedora's release mirrors.
This raw image was tested with NoCloud on KVM in BIOS and UEFI modes. Both the
compressed and expanded raw images have pinned SHA-256 hashes. See
`scripts/common.sh` for the URL and hashes. Hash checks detect changed content;
they do not verify Fedora's signing key.

The image and top-level Pi/Starship versions are pinned. Fedora packages and npm
transitive dependencies can change over time. This is a repeatable bootstrap,
not a promise of bit-for-bit identical guest disks. No extensions or provider
credentials are preloaded; set up Pi access after login.
