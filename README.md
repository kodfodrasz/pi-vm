# pi-vm Python tooling prototype

This branch contains the host and guest orchestration as standalone Python
scripts. Run them with `uv run --script`; each script carries its PEP 723
metadata. No host Bash or PowerShell wrapper is used.

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
uses it as an immutable backing file. Instance data is under `build/` (or
`PI_VM_BUILD`) and cache data can be changed with `PI_VM_CACHE`. Seed files are
rendered by `scripts/seed.py` and published atomically. `--force` only rebuilds
a stopped instance; forced stop verifies the exact QEMU executable, exact
`-drive file=` argument, and a pidfd before signalling.

The guest contract remains key-only SSH, enforcing SELinux, rootless Podman,
Samba password setup, trusted firewall sources, Pi package installation,
atomic bootstrap markers, and guest-generated deploy keys. First boot stages
all seed payloads under `/opt/pi-vm`; `assets/bootstrap.py` copies installed
configuration to `/etc/pi-vm` and installs the retry entrypoint at
`/usr/local/sbin/pi-vm-bootstrap`.

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
Only `local/bootstrap.py` is executable and the guest bootstrap runs it as
root with `PI_VM_LOCAL_DIR`; do not put credentials into a self-contained ISO.

## Windows / Hyper-V scope

`scripts/hyperv.py` is a deliberately bounded native feasibility prototype.
Its `image` action downloads and verifies the pinned Fedora Azure archive,
extracts it with Python `lzma`, validates the fixed VHD size and SHA-256, and
publishes it without replacing an existing possible backing file. Existing
VM status/start/stop use documented `Msvm_ComputerSystem` WMI/COM calls through
`pywin32`, and require `build/<id>/creation-complete` containing `complete` so
an unrelated VM named `pi-vm-<id>` cannot be managed accidentally.

Creating a new Generation 2 VM, converting the fixed VHD to VHDX, creating a
differencing child, attaching NoCloud media, and configuring firmware/network
resources are intentionally refused. The verified WMI
`DefineSystem`/resource-setting sequence and asynchronous image-management
result handling still need a Windows validation run. There is no PowerShell
fallback and no claim of unattended Hyper-V deployment readiness. These
behaviors remain unrun on Linux.

## Offline checks

`make test` checks seed contracts, `/opt/pi-vm` staging, key inventory,
Windows source normalization, resource parsing, exact QEMU PID safety,
atomic-publish refusal, bootstrap Python syntax/CLI parsing, and Hyper-V
platform validation without downloading an image, starting a VM, calling
Hyper-V, changing networking, or changing host dependencies.
