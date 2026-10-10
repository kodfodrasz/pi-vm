# pi-vm host tooling and guest bootstrap

Host orchestration remains in standalone Python scripts run with
`uv run --script`. The Fedora guest bootstrap is Bash plus a staged GNU
Makefile; it does not require Python to orchestrate guest setup. No host Bash
or PowerShell wrapper is used.

## Linux / KVM

Install Fedora host tools (`qemu-system-x86-core`, `qemu-img`, `xorriso`, and
`curl`) and ensure `/dev/kvm` is readable and writable:

```text
make test
make kvm-start INSTANCE=pipette
make kvm-status INSTANCE=pipette
make kvm-stop INSTANCE=pipette
```

The KVM tool downloads the pinned Fedora Cloud Base Generic qcow2 into
`~/.cache/pi-vm/images`, checks its size, SHA-256, and `qemu-img check`, then
uses it as an immutable backing file. Cache and VM artifacts are created with
private modes; instance data is under `build/` (or `PI_VM_BUILD`) and cache
data can be changed with `PI_VM_CACHE`. Seed files are rendered by
`scripts/seed.py` and published atomically without replacement. `--force` only
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
`scripts/seed.py --username developer` to select another non-root Linux account;
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

## Seed rendering

```text
uv run --script scripts/seed.py pipette --output build/pipette-seed.iso
uv run --script scripts/seed.py pipette --render-only build/seed-files
```

Linux uses `xorriso` through an argv-only subprocess. Windows uses the native
IMAPI2FS COM API through `pywin32`; it does not invoke PowerShell. UTF-8 BOMs
and CRLF source files are normalized before embedding. The output must not
already exist, so an old seed is never silently replaced.

Private payloads may be placed in ignored `local/`. Binary files are preserved.
`local/bootstrap.sh` is normalized to LF, staged mode `0700`, and run directly from `/opt/pi-vm/local` as
root with `PI_VM_LOCAL_DIR`. All local directories are restricted to `0700`. A legacy `local/bootstrap.py`, if present, is
preserved byte-for-byte as an inert payload and is not executed; migrate it to
Bash explicitly rather than relying on the old guest Python entrypoint. Do not
put credentials into a self-contained ISO.

## Windows / Hyper-V scope

`scripts/hyperv.py` is a deliberately bounded native feasibility prototype.
Its `image` action downloads and verifies the pinned Fedora Azure archive,
extracts it with Python `lzma`, validates the fixed VHD size and SHA-256, and
publishes it without replacing an existing possible backing file. Read-only VM status uses `Msvm_ComputerSystem` WMI/COM through `pywin32` and
requires `build/<id>/creation-complete` containing `complete` so an unrelated
VM named `pi-vm-<id>` cannot be inspected accidentally. Hyper-V start and stop
return an explicit unsupported error; no unsafe WMI mutation is attempted.

Creating a new Generation 2 VM, converting the fixed VHD to VHDX, creating a
differencing child, attaching NoCloud media, and configuring firmware/network
resources are intentionally refused. The verified WMI
`DefineSystem`/resource-setting sequence, guest shutdown component, and
asynchronous WMI output/job handling still need a Windows validation run. There
is no PowerShell fallback and no claim of unattended Hyper-V deployment
readiness. These behaviors remain unrun on Linux.

## Offline checks

`make test` runs the seed, guest Make/Bash, and validator suites. It checks
seed contracts, `/opt/pi-vm` staging, key inventory, copied-renderer Windows
source normalization, byte-preserved local payloads, Make dependency ordering,
marker recovery and idempotent retries, controlling-terminal installer detachment
with inert fakes, login greeting gates, credential recovery, named ipset
reconciliation, reboot readiness, semantic Pi versions, resource parsing, exact QEMU PID
safety, and Hyper-V cache locking/capacity checks. It does not download an
image, start a VM, call Hyper-V, change networking, or change host dependencies.
