---
name: validate-pi-vm
description: Test this Fedora Pi VM bootstrap after changes to guest assets, cloud-init, image conversion, or host scripts. Use for repeat KVM boot checks and Windows handoff checks.
---

# Validate pi-vm

The repository root is `../../..` from this skill directory. Read its `README.md`
first. Resolve script paths from that root.

1. Check free disk space and host RAM. Never put images or large test files in
   `/tmp`. Use `build/` and the image cache. Do not delete unrelated files.
2. Run `make test`. A skipped optional test is not a pass for that feature.
3. For guest or seed changes, boot a fresh VM with a unique instance ID and a
   free loopback SSH port. Use 1 CPU, 1024 MiB RAM, and an 8 GiB disk. Preserve
   any existing VM. Do not use destructive `--force` without a clear test scope.
4. Use a separate SSH known-hosts file for that VM. Wait at most five minutes
   for bootstrap. Check cloud-init status, schema, and the success marker.
   If it fails, read the log before changing anything.
5. Run `make validate INSTANCE=ID SSH_PORT=PORT` for the basic guest checks.
   For optional checks and a report, run `scripts/build/validate.py` directly with
   `--nested --balloon --report build/ID/validation.json`. Use a trusted
   `--known-hosts` file when needed. Never silently skip an option.
6. Check balloon support with QMP. Save the initial memory value, request a
   smaller value, query the result, then restore the initial value.
7. Test nested KVM with `tests/nested-kvm.py` inside the guest. Load the stock
   KVM module if needed. Do not install guest QEMU or libvirt just for this test.
8. Test graceful stop and restart. Verify the disk and marker survive.
9. Stop only the test VMs you created. Keep logs under `build/`. Write a short
   result with commands, passes, failures, skips, and the tested file state.

Linux can parse the PowerShell scripts and run the offline Hyper-V fixture, but
it cannot prove native Hyper-V cmdlets, Windows path/reparse behavior, image
conversion, or guest boot. Mark those as untested until someone runs them on
Windows. Never copy private SSH keys or Pi credentials.
