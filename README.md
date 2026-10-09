# pi-vm

Build a clean Fedora 44 x86-64 VM for Pi. The default hostname is `pipette`.
The user is `pi`, with fish as its login shell.

## Guest setup

The guest includes:

- Pi **1.1.0**, Node.js, npm, Git, ripgrep, and fd.
- Vim, micro, tmux, fish, fastfetch, and Starship **1.26.0**.
- Podman, Python, make, GCC, curl, jq, rsync, and unzip.
- Fedora kernel balloon drivers and Hyper-V guest services, without Azure guest agents.
- Samba home-directory sharing with Avahi and WSDD discovery.
- firewalld with SSH open everywhere and trusted LAN/VPN source zones.
- Pi web access, subagents, usage, keep-going, and usage-reset packages.
- The Kodfodrasz coding skill and preferred delegation/model settings.

Vim, tmux, and Starship settings come from this host. Fish uses a small,
portable config and completions checked against Pi 1.1.0. Starship is a pinned,
checksummed upstream binary because Fedora 44 has no Starship package.

No QEMU, libvirt, or KVM tools are installed in the guest. The kernel can still
support nested KVM. SELinux stays enforcing. Rootless Podman has user ID ranges
and user linger enabled.

SSH is allowed from every network but accepts public keys only. It uses the
keys in `assets/authorized_keys`. These are the combined keys from the original
user's authorized keys and public key files. Their IDs
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

The bootstrap writes `/var/lib/pi-vm/bootstrap-complete` only after the full
install succeeds. On failure it writes `/var/lib/pi-vm/bootstrap-failed`; the
validator reports that file without waiting for a timeout. Cloud-init does not
rerun the install after a reboot. After fixing a transient network problem, retry
inside the guest with:

```sh
sudo env VM_HOSTNAME=YOUR_HOSTNAME /usr/local/sbin/pi-vm-bootstrap
```

Use the hostname originally chosen for the VM (`pipette` by default). Fedora may report an early hostname warning before systemd is available. The
bootstrap sets the hostname later. Other cloud-init errors need investigation.
If a new VM reuses an SSH port, use a separate known-hosts file. Do not disable
host-key checks.

Host logs are `build/ID/serial.log` and `build/ID/qemu.log`. VM control uses a
local QMP socket in the same directory. Treat your build directory as private.

### Samba and network discovery

Samba exports each user's own home directory through the `[homes]` share.
Avahi advertises `_smb._tcp`, and WSDD supports Windows network discovery.
The initial Samba account is `pi`; first boot prints its random password and
these commands to the serial and cloud-init logs:

```sh
sudo smbpasswd pi
sudo rm -f /var/lib/pi-vm/samba-initial-password
```

The initial value also remains in the root-only file shown above until you
change it and remove the file.

firewalld allows key-only SSH in the public zone. The trusted zone accepts the
source ranges named in `assets/config/firewall-sources.conf`:

- `10.0.0.0/8` — home LAN/private Hyper-V network
- `192.168.100.0/24` — VPN

Samba itself accepts only loopback and those two ranges. Avahi and WSDD are
allowed in the public zone so clients can discover the share. Container bridge
ranges are not hard-coded into the VM firewall. `10.89.0.0/24` on the source
machine belongs to a specific root-owned Podman network, not to the LAN or VPN.

Forced stop verifies the QEMU executable and exact disk path before signalling
the process. Graceful and forced stops preserve the disk.

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
Python available as `python`, and 7-Zip available as `7z.exe`. The scripts use
APIs available in Windows PowerShell 5.1; PowerShell 7 can also run them.
They check the storage volume that holds each path, including mounted volumes.
Keep at least 8 GiB free for the cache and 12 GiB for the build files. If both
paths share a volume, at least 20 GiB must be free there. This is a conservative
check for new VM creation; restarting an existing VM needs no conversion space.
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

Starting an existing stopped VM preserves its disk and settings. A
`creation-complete` file confirms that the script finished its VM configuration.
A registered VM without that file is rejected so you can inspect it safely.
To rebuild, remove the old VM explicitly, then use `-Force` to replace its
instance files. `-Force` never replaces a registered VM.

Failed first creation removes only its own temporary files and new VM. If VM
removal or its state check fails, the disk is kept and the script prints its
path. Inspect that VM before any manual cleanup. Raw extraction is staged and
checked before it replaces a cache file. Shared bases are never resized after
children have been made.
Generated seed ISOs are reused: remove `build/seeds/ID.iso` explicitly if you
want new bootstrap settings for a **new disk**. `.gitattributes` keeps source
line endings at LF, and the renderer normalizes UTF-8 BOMs and CRLF before
embedding Linux files. Changing an ISO does not rerun
cloud-init on an old disk. Open the console with `vmconnect.exe localhost pi-vm-pipette`.

A real Windows host is still required to verify IMAPI2FS and Hyper-V behavior.
Follow `docs/hyperv-manual-test.md`.

## Pi setup and private configuration

Pi packages are installed through `pi install` with pinned package versions.
The VM receives a reviewed subset of this machine's Pi setup: preferred models,
subagent model assignments, cost-aware delegation rules, and the Kodfodrasz
skill. It does not receive authentication, trust decisions, sessions, usage
records, or provider credentials.

First boot creates `/home/pi/.ssh/pi-vm-deploy` inside the guest and prints only
its public key. After adding that public key as a deploy key to a private
repository, clone with:

```sh
GIT_SSH_COMMAND='ssh -i ~/.ssh/pi-vm-deploy -o IdentitiesOnly=yes' \
    git clone REPOSITORY
```

For configuration that should travel inside the NoCloud ISO, create an ignored
`local/` directory in this checkout. Its files are embedded under
`/etc/pi-vm/local/` with root-only permissions. If `local/bootstrap.sh` exists,
first boot runs it as root with `PI_VM_LOCAL_DIR=/etc/pi-vm/local`.

This keeps setup self-contained and needs no S3 service. A plaintext private key
placed in `local/` makes every copy of the seed ISO a credential. Prefer the
guest-generated deploy key. If fully unattended secret delivery is required,
use an encrypted local payload and provide its decryption key separately; a
self-contained unattended ISO cannot also conceal its own secret.

## Checks and repeatability

`make test` runs offline checks for shell, Python, rendered seeds, KVM process
handling, PowerShell, and VHD conversion. It does not download an image or boot
a VM. PowerShell and VHD checks run only when their host tools are available;
the large VHD case also requires enough free disk space.

### Check a running KVM guest

`make validate` checks an existing VM; it never starts or rebuilds one. It waits
up to five minutes for the real bootstrap marker, then checks cloud-init,
identity, exact Pi/Starship versions, root growth, key-only SSH settings,
rootless Podman, SELinux, and fish/Vim/tmux config loading. It also checks the
cloud-init instance ID, so using another VM's SSH port fails. It uses a temporary
tmux server and removes it afterward. Known early hostname warnings are
reported only when they match the exact known message; other cloud-init errors
and warnings fail the check. SSH policy is checked for the actual `pi`
connection, including user/address `Match` rules. A guest with `UseDNS` enabled
is rejected for manual `Match Host` verification.

```sh
make validate INSTANCE=pipette
python3 scripts/validate.py --instance pipette --nested --balloon \
    --report build/pipette/validation.json
```

The default check does not change memory or install software. `--nested` runs
the L2 instruction test using the stock kernel module. `--balloon` briefly
reduces memory by 256 MiB, then restores and checks the original target, even
if the test fails. Do not kill the validator during that test. A restoration
failure prints the original byte count for manual recovery.

SSH uses a per-instance known-hosts file at `build/ID/known_hosts`. It accepts a
first key but rejects changed keys. Authentication uses your normal OpenSSH
agent or identity files; the validator does not inspect or copy key material.
Pass `--known-hosts /absolute/path` directly to `scripts/validate.py` when you
already have a trusted file. JSON reports must stay inside that instance's
build directory. A failed check exits nonzero; optional flags never silently
skip their tests. Use `SSH_PORT=2223` for a VM on another port. The expected
hostname is `pipette`, not the instance ID; `--hostname` changes that check.

`tests/nested-kvm.py` runs a tiny L2 guest inside a test VM. It needs root and
the stock KVM kernel module, not a QEMU package.

The source is Fedora Cloud Base AmazonEC2 **44-1.7** from Fedora's release mirrors.
This raw image was tested with NoCloud on KVM in BIOS and UEFI modes. Both the
compressed and expanded raw images have pinned SHA-256 hashes. See
`scripts/common.sh` for the URL and hashes. Hash checks detect changed content;
they do not verify Fedora's signing key.

The image and top-level Pi/Starship versions are pinned. Fedora packages and npm
transitive dependencies can change over time. This is a repeatable bootstrap,
not a promise of bit-for-bit identical guest disks. No extensions or provider
credentials are preloaded; set up Pi access after login.
