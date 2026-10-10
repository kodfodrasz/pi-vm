# Windows Hyper-V integration checklist

Run these checks only on a disposable Windows host with Hyper-V enabled, an
existing virtual switch, elevated PowerShell, Storage cmdlets, and 7-Zip. They
perform downloads and VM lifecycle operations. They are not part of `make test`;
Linux offline fixtures do not validate native Windows cmdlets or guest boot.

1. Run `make test` on Linux, or run
   `pwsh -NoProfile -File tests/powershell-syntax.ps1` and
   `pwsh -NoProfile -File tests/hyperv.ps1` for offline PowerShell checks.
2. On Linux, create a seed with
   `uv run --script scripts/build/seed.py pipacs --hostname pipacs --output build/pipacs-seed.iso`.
   Copy this nonempty ISO to Windows. From the repository checkout, run
   `.\scripts\hyperv\hyperv.ps1 -Action start -Id pipacs -SeedIso C:\VMSeeds\pipacs-seed.iso -Switch "Default Switch"`.
   Windows does not run Python or `uv`; hostname and account settings come from
   the copied ISO.
3. Verify the downloaded archive and expanded `.vhd` against the pinned SHA-256
   values. The expanded fixed VHD must be 5368709632 bytes with a
   5368709120-byte virtual size. Confirm the converted parent is a dynamic VHDX,
   resized to the requested size, and the instance disk is a differencing child.
4. Confirm Generation 2, Secure Boot off, CPUs with nested virtualization
   exposed, and static memory by default. On a fresh instance, verify
   `-DynamicMemory` with 1024 MiB minimum, 2048 MiB startup, and 8192 MiB
   maximum. Test an external switch separately; do not change host networking.
5. Find the guest IP with
   `Get-VMNetworkAdapter -VMName pi-vm-pipacs | Select-Object -ExpandProperty IPAddresses`.
   Log in, wait for cloud-init and bootstrap completion, and verify hostname,
   instance ID, key-only SSH, disabled SELinux, rootless Podman, and Pi setup.
6. Run `status`, graceful `stop`, restart with `start`, and forced stop only
   when data loss is acceptable.
7. Run `delete` on a stopped instance and confirm the exact VM registration and
   private child are removed while the cached parent remains. On a running owned
   VM, `delete` must refuse without `-Force`; with `-Force`, it must turn off the
   exact owned VM before removing registration. Test failed stop/remove and
   unexpected files: instance files must remain for manual inspection.
8. Test a supplied ISO again and verify it is unchanged. Never remove a parent
   VHDX while differencing children depend on it.

The Linux fixture does not prove Windows PowerShell 5.1 path rules, drive/UNC
normalization, junction or reparse-ancestor detection, Hyper-V VM-ID parameter
binding, native VHD conversion, switch attachment, guest boot, or cleanup after
an interrupted host operation. These are the remaining Windows checks; this
repository makes no claim that they have been run until the checklist is
completed on a disposable Windows host.
