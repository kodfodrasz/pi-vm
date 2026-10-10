# Windows hyperv deployment

This launcher manages an existing Windows hyperv installation. Windows needs
PowerShell with the Hyper-V and Storage modules, 7-Zip, and an existing virtual
switch. It does not need Python, `uv`, a Python extension, or a C# build shim.

Create the Linux NoCloud ISO on Linux:

```sh
uv run --script scripts/build/seed.py pipacs --hostname pipacs --output build/pipacs-seed.iso
```

Copy that nonempty ISO to Windows. Run from an elevated PowerShell prompt with
an absolute path:

```powershell
.\scripts\hyperv\hyperv.ps1 -Action start -Id pipacs -SeedIso C:\VMSeeds\pipacs-seed.iso -Switch "externalname" -MemoryMB 2048 -MinimumMemoryMB 1024 -MaximumMemoryMB 8192 -DynamicMemory
.\scripts\hyperv\hyperv.ps1 -Action status -Id pipacs
Get-VMNetworkAdapter -VMName pi-vm-pipacs | Select-Object -ExpandProperty IPAddresses
ssh pi@<guest-IP>
.\scripts\hyperv\hyperv.ps1 -Action stop -Id pipacs
.\scripts\hyperv\hyperv.ps1 -Action stop -Id pipacs -Force
.\scripts\hyperv\hyperv.ps1 -Action delete -Id pipacs -Force
```

Omit `-DynamicMemory` for static memory (the default). `-MemoryMB` is startup
memory; dynamic memory validates the minimum, startup, and maximum values.
The `Default Switch` provides Windows-managed NAT. An external switch provides
LAN access; an inherited or nested bridge requires the outer host's networking
and hyperv settings to be prepared separately. This script does not create or
modify switches.

The launcher downloads the pinned Fedora Azure archive, verifies the archive
and expanded fixed VHD, and extracts it with 7-Zip. It converts the fixed VHD
to a cached dynamic VHDX parent and creates a private differencing child for
each instance. Keep the immutable parent with its children; a child is not a
standalone backup.

`start` never recursively removes an existing instance directory, even with
`-Force`; use the ownership-checked `delete` before a fresh start.

`delete` is fail-closed. It requires the creation-complete marker and identity
metadata, exact VM registration, and the expected private child-to-parent disk
relationship. A running owned VM must be stopped with `-Force`; registration is
removed before managed instance files are removed. The cached parent is never
removed. If stop/removal or ownership checks fail, or an unexpected file remains,
leave the directory in place and perform manual cleanup only after inspecting
the VM registration and VHD chain. These checks are fail-closed for trusted
local directories; they are not a race-proof boundary against a privileged
process changing paths concurrently.

The Windows command parser and offline hyperv fixtures are in `tests/`. The
native Windows lifecycle and guest boot remain an actual Windows validation task;
see `docs/hyperv-manual-test.md`.
