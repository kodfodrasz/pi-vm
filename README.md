# pi-vm host tooling and guest bootstrap

Linux KVM management and NoCloud seed rendering use standalone Python scripts
run with `uv run --script`; both are Linux host operations. Windows Hyper-V management
uses native PowerShell cmdlets. The Linux seed builder is
`scripts/build/seed.py`; Windows consumes a copied ISO and the same guest assets. The Fedora guest bootstrap is Bash plus a staged GNU Makefile;
it does not require Python to orchestrate guest setup.

## Linux / KVM

Install the Fedora host tools (`qemu-system-x86-core`, `qemu-img`, `xorriso`,
and `curl`). KVM must be enabled and `/dev/kvm` must be readable and writable
by the account running QEMU. The launcher also requires `vmx` (Intel) or `svm`
(AMD) to be exposed. If this Linux host is itself a KVM VM, enable nested KVM
in the outer host and expose a host-passthrough (or equivalent virtualization-
capable) CPU to it. Check the result with `virsh capabilities` and, on Linux,
`cat /sys/module/kvm_intel/parameters/nested` or
`cat /sys/module/kvm_amd/parameters/nested`; do not change these settings
blindly.

### Default network: isolated QEMU user NAT

Without `--bridge`, QEMU uses its user-mode network. The guest can make
outbound connections, including the first-boot downloads, without root,
bridge setup, or changes to the host LAN. SSH is forwarded only to the host's
loopback address, so it is not reachable directly from other LAN machines.
This is NAT with a localhost port forward, not a fully disconnected network:
remove or block the forward and guest outbound traffic separately if complete
isolation is required.

Use the Make targets for the default network:

```text
make kvm-start INSTANCE=nat-demo
make kvm-status INSTANCE=nat-demo
make kvm-stop INSTANCE=nat-demo                 # graceful QMP powerdown
uv run --script scripts/kvm/kvm.py stop nat-demo --force  # forced, safety-checked
make test                                        # offline checks
```

The equivalent direct launch is
`uv run --script scripts/kvm/kvm.py start nat-demo --hostname nat-demo --ssh-port 2222`.
Log in with `ssh -p 2222 pi@127.0.0.1`. Use `status` to check whether it is
running. Choose a different `--ssh-port` for another active instance.

### Optional LAN bridge

Bridged networking is opt-in and the CLI currently accepts only `br0`.
It attaches the guest through QEMU's Linux bridge helper; it does not create
or configure the bridge. The host must already have a working `br0`, and the
package-provided helper configuration must narrowly allow `br0` (commonly an
entry in `/etc/qemu/bridge.conf`). Check the QEMU package documentation and
helper file ownership/permissions on the distribution; do not add setuid bits
or run `chmod` blindly.

On a Linux host, identify the active uplink and inspect its settings first.
Have local or Hyper-V console access: changing an active uplink can disconnect
SSH. Retain the original profile rather than turning it into a bridge port.

```sh
nmcli connection show --active
UPLINK_PROFILE="your-uplink-profile"
UPLINK_DEVICE="enp1s0"
nmcli connection show "$UPLINK_PROFILE"
UPLINK_MAC=$(cat "/sys/class/net/$UPLINK_DEVICE/address")
```

The following example is for a wired DHCP uplink and an unused `br0` name.
Create inactive bridge and port profiles. Replace `public` if the original
connection uses another firewall zone. Copy any custom DHCP client ID, MTU,
routes, DNS, and IPv6 policy from the original profile before activation.

```sh
sudo nmcli connection add type bridge ifname br0 con-name br0 autoconnect no \
  bridge.mac-address "$UPLINK_MAC" connection.zone public \
  ipv4.method auto ipv6.method auto
sudo nmcli connection add type ethernet ifname "$UPLINK_DEVICE" \
  con-name br0-port controller br0 port-type bridge autoconnect no
```

For static networking, put the original address, gateway, routes, DNS, and
IPv6 settings on `br0` instead of using `ipv4.method auto`. The management IP
belongs to `br0`; its physical port has no IP configuration. This is not a
universal migration recipe, especially for Wi-Fi, VLANs, or multiple uplinks.

Use NetworkManager's interactive checkpoint from the console to activate the
port and its bridge controller:

```sh
nmcli device checkpoint --help
sudo nmcli device checkpoint --timeout 180 -- nmcli connection up br0-port
```

Check the address on `br0`, default route, gateway reachability, and DNS from
another terminal before confirming the checkpoint. **Without confirmation,
the checkpoint rolls back at timeout.** It protects device state, not every
persistent profile edit; keep the original profile for manual recovery. For
remote automation, also arrange an independent timed rollback before activation.

After confirming connectivity, enable the new profiles on future boots and
prevent the old profile from reclaiming the uplink:

```sh
sudo nmcli connection modify br0 connection.autoconnect yes
sudo nmcli connection modify br0-port connection.autoconnect yes
sudo nmcli connection modify "$UPLINK_PROFILE" connection.autoconnect no
```

To undo this setup, stop bridged guests first, then use the console:

```sh
sudo nmcli connection modify br0 connection.autoconnect no
sudo nmcli connection modify br0-port connection.autoconnect no
sudo nmcli connection down br0
sudo nmcli connection modify "$UPLINK_PROFILE" connection.autoconnect yes
sudo nmcli connection up "$UPLINK_PROFILE"
```

Do not delete the original profile until you have tested recovery. No host
reboot is needed for the bridge setup.

After `br0` is ready and authorized, launch a distinct bridge instance:

```text
uv run --script scripts/kvm/kvm.py start lan-demo --hostname lan-demo --bridge br0
uv run --script scripts/kvm/kvm.py status lan-demo
uv run --script scripts/kvm/kvm.py stop lan-demo                 # graceful
uv run --script scripts/kvm/kvm.py stop lan-demo --force         # forced
```

The launcher prints an SSH hint, but bridged SSH needs the guest's DHCP lease:
find the lease in the router or DHCP server, or inspect the bridge/network
neighbor tables, then use `ssh pi@<guest-LAN-IP>`. `10.0.191.70` is only an
example of a discovered address, not a fixed setting. The `--hostname` value
is applied when the instance seed is first created; use a new instance or
`--force` a stopped instance before changing that seed.

### KVM inside Hyper-V

For Fedora nested inside a Windows Hyper-V VM, these are outer-host checks and
not launcher commands. In an elevated PowerShell, inspect the switch and
adapter:

```powershell
Get-VMSwitch | Format-Table Name,SwitchType
Get-VMNetworkAdapter -VMName "OuterLinux" |
    Format-List VMName,Name,SwitchName,MacAddress,MacAddressSpoofing
Get-VMProcessor -VMName "OuterLinux" |
    Format-List ExposeVirtualizationExtensions
```

The outer VM needs an **External** virtual switch. With the outer VM stopped,
an administrator can expose virtualization and, when required for a nested
bridge, enable MAC spoofing:

```powershell
Set-VMProcessor -VMName "OuterLinux" -ExposeVirtualizationExtensions $true
Set-VMNetworkAdapter -VMName "OuterLinux" -MacAddressSpoofing On
```

The external Hyper-V switch connects the outer VM to the physical LAN; it is
not the Fedora guest's `br0`. Inside Fedora, configure `br0` as described
above. Nested virtualization, the Windows edition/build, firmware, and
hardware must support this arrangement. If MAC spoofing is prohibited, use
the default QEMU user NAT instead. These PowerShell commands prepare an existing
outer Hyper-V VM; native VM creation is described below.

The KVM tool downloads the pinned Fedora Cloud Base Generic qcow2 into
`~/.cache/pi-vm/images`, checks its size, SHA-256, and `qemu-img check`, then
uses it as an immutable backing file. Cache and VM artifacts are created with
private modes; instance data is under `build/` (or `PI_VM_BUILD`) and cache
data can be changed with `PI_VM_CACHE`. Seed files are rendered by
`scripts/build/seed.py` and published atomically without replacement. `--force` only
rebuilds a stopped instance; forced stop verifies the exact QEMU executable,
exact `-drive file=` argument, and a pidfd before signalling.

The guest contract remains key-only SSH, intentionally disabled SELinux, rootless
Podman, Samba password setup, trusted firewall sources, the current user-local managed Pi release,
atomic bootstrap markers, and guest-generated deploy keys. First boot stages
all seed payloads under `/opt/pi-vm`; `assets/bootstrap.sh` validates the root
and hostname contract, installs `make` if needed, and invokes the staged
`Makefile`. The Makefile installs directly from `/opt/pi-vm` into final system/user
destinations without duplicating the staged payload. It installs the retry entrypoint at `/usr/local/sbin/pi-vm-bootstrap`. After a
failure, inspect `/var/lib/pi-vm/bootstrap-failed` and rerun
`sudo /usr/local/sbin/pi-vm-bootstrap`; a later successful retry keeps
`recovered_from_failure=true` in the completion marker. The requested hostname
precedence is explicit `VM_HOSTNAME`, then the validated atomic value in
`/var/lib/pi-vm/hostname`, then the system hostname. The selected value is
saved before any make or package installation, so an environment-free retry
preserves the seed hostname. The one-time Samba
password is intentionally printed to the bootstrap output (including
cloud-init/serial output) and the root-only `/var/lib/pi-vm/bootstrap.log`;
change it with `sudo smbpasswd pi`, then remove `~/samba-initial-password`.
The saved password is atomic, mode `0600`, and owned by the configured user.
Only creation of a new Samba account prints it; retries reuse an interrupted
creation's saved password and never reset an existing account.

## Personal guest policy

The seed account defaults to `pi`. Use `PI_USER=developer make seed` or
`scripts/build/seed.py --username developer` to select another non-root Linux account;
`PI_USER=developer make kvm-start` forwards that environment to seed creation.
Cloud-init creates the account with `/home/<username>` and wheel membership.
Bootstrap never creates a fallback account: it fails clearly if absent, uses
its actual home and primary group, and persists the username for retries.
For a non-default account, pass `--username developer` to the validator and
use that account in SSH commands (the KVM tool's printed SSH hint assumes pi).

Fedora supplies Node.js/npm. Bootstrap downloads `https://pi.dev/install.sh`
and executes it as the account using non-login `su` with explicit `sh`, HOME,
and home working directory. Fedora `setsid --fork --wait` removes the controlling
terminal even during interactive retries: redirecting stdin alone would not
prevent the installer's `/dev/tty` confirmation. Pi lives under
`~/.pi/agent/install`, with `~/.local/bin` on PATH. The core is latest rather
than pinned; `pi update` updates it later. Extensions remain pinned and are
installed with native `pi install npm:...` commands. Trust in the current HTTPS
installer and release metadata is intentional; first boot requires network
access and Fedora Node.js must meet the current installer requirements.

SELinux is fully disabled by `grubby --update-kernel=ALL --args=selinux=0`
and `SELINUX=disabled` in `/etc/selinux/config`. Cloud-init updates and upgrades
packages. Its final `power_state` module reboots only after successful bootstrap
if SELinux was still active. Successful manual retries schedule the same reboot
one minute later. Completion records the boot ID and reboot requirement;
validation waits for a different boot ID when required and demands `Disabled`,
not Permissive. Failures never request reboot. Already-disabled boots do not
request another reboot. Disabling SELinux trades away its isolation; this is
an explicit personal-use policy, not a hardened deployment profile.

Firewalld's named `home_lan` (10.0.0.0/8) and `vpn` (192.168.100.0/24) hash:net
ipsets are sourced from `/opt/pi-vm/config/firewall-sources.conf`, created only
if absent, and attached to the trusted zone. Reconciliation preserves extra
entries; no Podman CIDR is trusted. Public networks retain key-only SSH and
mDNS/WSD discovery.

Bootstrap generates `~/README.md` only if absent, with machine/account-specific
instructions. It preserves existing README and profile configurations on reruns;
managed login hooks and Pi settings are reconciled. Bash and fish greet only
interactive terminal logins, not SSH commands or provisioning. The shared small
display script shows text before the literal `<!-- END_OF_WALL_MESSAGE -->`
line, never that line or later text, and prints nothing if the sentinel is
absent. This explicit boundary does not depend on H2 headings. It shows only
password location/change guidance, never the secret. Dismiss it with
`touch ~/.readme-dismissed`; remove that file to restore it. There is no
persistent first-login marker.

### Guest PowerShell

The staged `install-powershell.sh` is best effort for Fedora. It resolves the
latest official stable x86_64 PowerShell RPM, verifies the exact GitHub release
asset SHA-256 (using `hashes.sha256` when the API has no digest), checks RPM
metadata, and installs that already verified local RPM with repository
signature checks enabled. Fedora support for this upstream RPM is not guaranteed;
failure remains visible rather than silently installing an unverified package.

## Seed rendering

```text
uv run --script scripts/build/seed.py pipette --output build/pipette-seed.iso
uv run --script scripts/build/seed.py pipette --render-only build/seed-files
```

`--render-only` is pure Python and may stage files on another platform, but
ISO creation uses Linux `xorriso` through an argv-only subprocess. ISO creation
is Linux-only; Windows never invokes Python, `uv`, COM, or a Windows ISO builder. UTF-8 BOMs and
CRLF source files are normalized before embedding. The output must not already
exist, so an old seed is never silently replaced.

Hostnames may be a single Linux label or a dotted FQDN. Every label is 1-63
ASCII letters or digits with interior hyphens only, and the complete name is
limited to 64 characters. The 64-character limit follows Linux `HOST_NAME_MAX`
and `hostnamectl` static-hostname compatibility; DNS names can have a larger
wire-format limit, but those names are not accepted here. Empty labels,
trailing dots, whitespace, shell metacharacters, and leading or trailing
hyphens are rejected before rendering or guest bootstrap.

Private payloads may be placed in ignored `local/`. Binary files are preserved.
`local/bootstrap.sh` is normalized to LF, staged mode `0700`, and run directly from `/opt/pi-vm/local` as
root with `PI_VM_LOCAL_DIR`. All local directories are restricted to `0700`. A legacy `local/bootstrap.py`, if present, is
preserved byte-for-byte as an inert payload and is not executed; migrate it to
Bash explicitly rather than relying on the old guest Python entrypoint. Do not
put credentials into a self-contained ISO.

## Windows / Hyper-V

Use an elevated PowerShell on a Windows host with Hyper-V enabled, the
`Hyper-V` PowerShell module and Storage cmdlets available, and 7-Zip installed.
Windows PowerShell 5.1 or PowerShell 7 with the Hyper-V module can run the
launcher. It finds an application `7z.exe` on PATH first, then checks the
standard `Program Files\7-Zip\7z.exe` and `Program Files (x86)\7-Zip\7z.exe`
installer locations. It does not modify the process, user, or machine PATH.
Windows requires no Python, `uv`, Python packages, or C# build shim: create the
ISO on Linux and copy the existing nonempty absolute ISO to Windows. First
guest boot also requires internet access.

List existing switches with `Get-VMSwitch`. The launcher does not create or
modify switches. An **External** switch puts the guest on the physical LAN;
choose only a trusted network. The default **Default Switch** uses Windows
managed NAT and DHCP rather than direct LAN attachment. It permits outbound
access and host-to-guest communication; it is not complete isolation and does
not provide the Linux launcher's localhost SSH port forward.

From the repository root, create `pipacs` (replace `Your External Switch` with
an existing switch name, or use `Default Switch`):

```powershell
.\scripts\hyperv\hyperv.ps1 -Action start -Id pipacs -SeedIso C:\VMSeeds\pipacs.iso -Switch "Your External Switch" -MemoryMB 2048 -CpuCount 2 -DiskSize 16GiB
# Or, on a separate fresh instance:
.\scripts\hyperv\hyperv.ps1 -Action start -Id pipacs -SeedIso C:\VMSeeds\pipacs.iso -Switch "Default Switch" -DynamicMemory -MemoryMB 2048 -MinimumMemoryMB 1024 -MaximumMemoryMB 8192
.\scripts\hyperv\hyperv.ps1 -Action status -Id pipacs
Get-VMNetworkAdapter -VMName pi-vm-pipacs | Select-Object -ExpandProperty IPAddresses
ssh pi@<guest-IP>
vmconnect.exe localhost pi-vm-pipacs
.\scripts\hyperv\hyperv.ps1 -Action stop -Id pipacs          # graceful guest shutdown
.\scripts\hyperv\hyperv.ps1 -Action stop -Id pipacs -Force   # immediate power off; may lose data
.\scripts\hyperv\hyperv.ps1 -Action delete -Id pipacs -Force
```

If Hyper-V has not reported an IP yet, wait for guest services or find the
DHCP lease on the router for an external switch. Status reports Hyper-V state,
not bootstrap readiness. Inspect `cloud-init status --long` and
`/var/lib/pi-vm/bootstrap-complete` in the guest. Log in using the account baked
into the copied Linux seed. Hostname and account settings are seed-generation
inputs, not Windows launcher parameters; the seed stages the same `/opt/pi-vm`
assets, package upgrades, SELinux disablement, and success-only reboot policy as Linux.

To bypass seed creation entirely, supply an existing **absolute** ISO path:

```powershell
.\scripts\hyperv\hyperv.ps1 -Action start -Id pipacs -SeedIso C:\VMSeeds\pipacs.iso -Switch "Default Switch"
```

A supplied ISO is used unchanged; its own cloud-init identity/account settings
apply. The Windows launcher never creates an ISO and has no Python or `uv`
dependency. Generate it on Linux, for example with `uv run --script
scripts/build/seed.py pipacs --hostname pipacs --output build/pipacs-seed.iso`,
then copy that absolute file to Windows. Seeds are never silently replaced;
use a new ID or explicitly remove an unused old seed to change its identity.
Treat seed media as private: it includes any ignored `local/` payload.

The launcher pins the Fedora 44 Azure `.vhdfixed.xz` archive, verifies its
SHA-256, then verifies the expanded fixed VHD's length (5 GiB plus a 512-byte
footer), SHA-256, and native metadata. It uses a `.vhd` suffix for Hyper-V,
converts to a dynamic VHDX parent, resizes the parent before creating the
instance's differencing VHDX, and configures a Generation 2 VM with Secure Boot
off and nested virtualization exposed. Memory is static by default;
`-DynamicMemory` opts in. `-MemoryMB` is the startup allocation; dynamic guests
may be adjusted between `-MinimumMemoryMB` (default 1024 MiB) and
`-MaximumMemoryMB` (default startup memory), subject to host availability. A
maximum is not a promise that the host can provide that much memory at startup.
The bounds apply only with `-DynamicMemory`; static memory keeps its existing
behavior. For example:

```powershell
.\scripts\hyperv\hyperv.ps1 -Action start -Id pipacs -SeedIso C:\VMSeeds\pipacs.iso -DynamicMemory -MemoryMB 2048 -MinimumMemoryMB 1024 -MaximumMemoryMB 8192
```

Nested virtualization is a separate compatibility setting: exposing
virtualization extensions lets this direct Hyper-V guest run nested KVM when the
Windows host supports it, but it does not guarantee dynamic-memory capacity.
Do not confuse this direct Hyper-V guest with an outer nested host VM or assume
that settings for one provide the other's resources.

Each instance disk is a live differencing VHDX child of the cached converted
parent. Retain the parent and preserve the parent relationship when moving or
exporting a VM; copy or export the complete chain and verify its paths before
starting it elsewhere. A live differencing disk is not a standalone backup.

Storage preflight reserves 12 GiB for cache and 20 GiB for build; when both are
on the same volume it requires 32 GiB free. Exclusive cache/build locks and
staged publication protect concurrent operations. Creation failures remove
only owned instance files once VM absence is certain. If registration or
rollback is uncertain, files remain for manual inspection. Never delete a
parent VHDX while differencing children depend on it.

`start` restarts a stopped, completed registered VM without reconfiguring it. If
no VM is registered, it also accepts an existing ordinary instance directory
with the supplied seed and other regular user files. It rejects the managed
names `disk.vhdx`, `ownership.json`, and `creation-complete` (case-insensitive),
directories, and reparse points before creation. It never overwrites existing
files; `-Force` is not permission to do so. The cache directory must not equal
or be inside the per-instance directory; sibling and parent cache directories
remain valid.

`delete` requires the recorded creation identity, exact VM registration, the
expected private differencing child/parent relationship, and the recorded
preexisting-file allowlist. A running owned VM needs `-Force`, which turns off
that exact VM before removing its registration. Registration is removed before
managed-file cleanup; the cached parent, supplied seed, and preexisting user
files are preserved. A preexisting instance directory is retained even when
empty. Failed stop, failed removal, an unexpected file, or uncertain ownership
preserves files for manual inspection. Native Windows integration and guest boot
checks are separate from the offline fixtures; see [the Windows checklist](docs/hyperv-manual-test.md).

## Offline checks

`make test` runs the seed, guest Make/Bash, and validator suites. It checks
seed contracts, `/opt/pi-vm` staging, key inventory, copied-renderer Windows
source normalization, byte-preserved local payloads, Make dependency ordering,
marker recovery and idempotent retries, controlling-terminal installer detachment
with inert fakes, login greeting gates, credential recovery, named ipset
reconciliation, reboot readiness, semantic Pi versions, resource parsing, exact QEMU PID
safety, and Linux-only seed rendering. When `pwsh` is available it also
runs the actual PowerShell parser and isolated Hyper-V command fixtures for
seed invocation, cache hashes/length, native disk sizing, storage capacity,
locks, rollback, registration ownership, and lifecycle dispatch. If `pwsh` is
absent those checks explicitly report SKIP. The suites do not download an
image, start a VM, call real Hyper-V, change networking, or change host dependencies.
