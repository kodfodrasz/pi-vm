# Windows hyperv deployment

This launcher manages an existing Windows hyperv installation. Windows needs
PowerShell with the Hyper-V and Storage modules, 7-Zip, and an existing virtual
switch. The launcher uses an application `7z.exe` found on PATH first, then the
standard `Program Files\7-Zip\7z.exe` or `Program Files (x86)\7-Zip\7z.exe`
installer location. It does not modify process, user, or machine PATH. It does
not need Python, `uv`, a Python extension, or a C# build shim.

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

Omit `-DynamicMemory` for static memory (the default). New VMs also use
Production checkpoints and enable the `Guest Service Interface` integration
service. Existing integration services are left unchanged, and automatic
checkpoint scheduling is not changed. `-MemoryMB` is startup memory; dynamic
memory validates the minimum, startup, and maximum values. The `Default Switch`
provides Windows-managed NAT. An external switch provides LAN access; an
inherited or nested bridge requires the outer host's networking and hyperv
settings to be prepared separately. This script does not create or modify
switches.

To apply the two VM defaults to an already-created `pi-vm-pipacs`, run these
commands in elevated PowerShell. They use the VM object and enable only the
Guest Service Interface; the launcher does not run them automatically for an
existing VM:

```powershell
$vm = Get-VM -Name pi-vm-pipacs
Set-VM -VM $vm -CheckpointType ProductionOnly
$guestService = @(Get-VMIntegrationService -VM $vm |
    Where-Object { $_.Name -ceq 'Guest Service Interface' })
if ($guestService.Count -ne 1) { throw 'Guest Service Interface was not found' }
if (-not $guestService[0].Enabled) {
    Enable-VMIntegrationService -VMIntegrationService $guestService[0]
}
```

Hyper-V's documented PowerShell object exposes integration services through
`Get-VMIntegrationService` and the `VMIntegrationComponent` pipeline; it does
not document a GUID selector/property for this cmdlet. The launcher therefore
uses the canonical `Guest Service Interface` name. On a localized Windows
installation, that service name may be localized and the selection command
must be adjusted accordingly.

The launcher downloads the pinned Fedora Azure archive, verifies the archive
and expanded fixed VHD, and extracts it with 7-Zip. It converts the fixed VHD
to a cached dynamic VHDX parent and creates a private differencing child for
each instance. Keep the immutable parent with its children; a child is not a
standalone backup.

`start` accepts an existing ordinary instance directory, including one that
already contains the supplied seed ISO and other regular user files. It never
overwrites those files and `-Force` does not change that rule. The reserved
managed names `disk.vhdx`, `ownership.json`, and `creation-complete`
(case-insensitive), directories, and reparse points are rejected before VM or
disk creation. A supplied seed inside the instance is recorded as a preexisting
file and is preserved. The cache directory must remain separate from and
outside the per-instance directory; a sibling or parent cache directory is
allowed.

`delete` is fail-closed. It requires the creation-complete marker and identity
metadata, exact VM registration, the expected private child-to-parent disk
relationship, and the recorded preexisting-file allowlist. A running owned VM
must be stopped with `-Force`; registration is removed before managed instance
files are removed. The cached parent, supplied seed, and recorded user files are
never removed. A directory that existed before creation is also retained, even
when it becomes empty. If stop/removal or ownership checks fail, an unexpected
file remains, or an unsafe entry is found, leave the directory in place and
perform manual cleanup only after inspecting the VM registration and VHD chain.
These checks are fail-closed for trusted local directories; they are not a
race-proof boundary against a privileged process changing paths concurrently.

The Windows command parser and offline hyperv fixtures are in `tests/`. The
native Windows lifecycle and guest boot remain an actual Windows validation task;
see `docs/hyperv-manual-test.md`.
