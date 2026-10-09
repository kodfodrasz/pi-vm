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

The guest contract remains key-only SSH, enforcing SELinux, rootless
Podman, Samba password setup, trusted firewall sources, Pi package installation,
atomic bootstrap markers, and guest-generated deploy keys. First boot stages
all seed payloads under `/opt/pi-vm`; `assets/bootstrap.sh` validates the root
and hostname contract, installs `make` if needed, and invokes the staged
`Makefile`. The Makefile installs durable configuration under `/etc/pi-vm` and
installs the retry entrypoint at `/usr/local/sbin/pi-vm-bootstrap`. After a
failure, inspect `/var/lib/pi-vm/bootstrap-failed` and rerun
`sudo /usr/local/sbin/pi-vm-bootstrap`; a later successful retry keeps
`recovered_from_failure=true` in the completion marker.

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
`local/bootstrap.sh` is normalized to LF, installed mode `0700`, and run as
root with `PI_VM_LOCAL_DIR`. A legacy `local/bootstrap.py`, if present, is
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
marker recovery and idempotent retries, resource parsing, exact QEMU PID
safety, and Hyper-V cache locking/capacity checks. It does not download an
image, start a VM, call Hyper-V, change networking, or change host dependencies.
