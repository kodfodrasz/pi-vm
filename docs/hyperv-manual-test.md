# Windows 11 manual test

These are the remaining Windows checks. Linux mock tests are not a substitute.
Use PowerShell as Administrator from the repository root. You need Hyper-V,
Python (`python`), and 7-Zip (`7z`). Use a local disk with enough free space.

## 1. Create a small VM

Use a new test ID. Do not point it at a disk from another VM.

```powershell
.\scripts\hyperv.ps1 -Action start -Id win-check -CpuCount 1 -MemoryMB 1024 -DiskSize 8GiB
```

Expected: the script checks free space, downloads and verifies Fedora if needed,
creates a NoCloud ISO, makes an 8 GiB VHDX base, and creates a child disk.
A later VM of the same size should reuse that base without resizing it.

## 2. Check the host settings

```powershell
$vm = Get-VM -Name pi-vm-win-check
Get-VMProcessor -VMName $vm.Name | Select-Object Count,ExposeVirtualizationExtensions
Get-VMMemory -VMName $vm.Name | Select-Object DynamicMemoryEnabled,Startup
$disk = (Get-VMHardDiskDrive -VMName $vm.Name).Path
$child = Get-VHD -Path $disk
$child | Select-Object VhdType,Size,ParentPath
Get-VHD -Path $child.ParentPath | Select-Object VhdType,Size,ParentPath
Get-VMDvdDrive -VMName $vm.Name | Select-Object Path
```

Expected: one CPU, nested extensions on, static 1024 MiB RAM, a **Differencing**
child disk, and an 8 GiB base with no parent. The DVD path should be
`build/seeds/win-check.iso`. The VM should be Generation 2, with Secure Boot off.

## 3. Check the guest

```powershell
vmconnect.exe localhost pi-vm-win-check
Get-VMNetworkAdapter -VMName pi-vm-win-check | Select-Object -ExpandProperty IPAddresses
```

Get the IP address from the console if Hyper-V has not reported it yet. Connect
with `ssh pi@IP_ADDRESS` using an authorized key. The guest hostname is `pipette`,
not `win-check`. Wait for first boot to finish, then run inside the guest:

```sh
sudo cloud-init status --long
sudo cloud-init schema --system
test -f /var/lib/pi-vm/bootstrap-complete
hostname
pi --version
starship --version
findmnt /
podman info --format '{{.Host.Security.Rootless}}'
lsmod | grep -E 'hv_balloon|hv_storvsc|hv_netvsc|hv_vmbus'
```

Expected: no cloud-init errors, a success marker, Pi 1.1.0, Starship 1.26.0,
a root filesystem close to 8 GiB, and rootless Podman. The kernel should load
Hyper-V storage, network, and bus drivers. An early hostname warning can occur
before systemd is available; other warnings need investigation.

## 4. Check restart and nested KVM

```powershell
.\scripts\hyperv.ps1 -Action stop -Id win-check
.\scripts\hyperv.ps1 -Action start -Id win-check
```

Expected: restart keeps the same disk, files, settings, and SSH host key.
Cloud-init should not reinstall the guest software.

For a nested execution check, copy `tests/nested-kvm.py` into the guest. Load
`kvm_amd` on AMD or `kvm_intel` on Intel, then run `sudo python3 nested-kvm.py`.
Expected: `PASS: nested KVM executed an L2 halt instruction`. Do not install
QEMU or libvirt just for this check.

## 5. Record results before cleanup

Record the Windows build, CPU type, PowerShell version, script commit, and
pass/fail results. Keep the script error text and cloud-init log if boot fails.
Check disk preservation and actual balloon behavior separately; static memory
is the default, so normal deployment does not exercise dynamic reclamation.

Stop only the test VM you created. If you remove its registration, its disk
files may remain. Inspect them before deleting them. Never delete the shared
base while any child still refers to it. Do not use `-Force` as a general
cleanup command: it will not replace a registered VM.
