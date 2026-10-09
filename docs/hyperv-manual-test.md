# Windows native feasibility checks

This prototype does not create or boot a Hyper-V VM. The following checks are
for a disposable Windows 11 host with Hyper-V enabled and Python/uv available.
They are not part of `make test` and were not run by the Linux implementation
worker.

1. Run `uv run --script scripts/hyperv.py image` and verify that the archive
   and extracted fixed VHD are created under the selected cache. Check the
   reported hashes against Fedora's signed release checksum publication.
2. Confirm that a bad archive or fixed VHD is rejected and the existing cache
   file remains unchanged.
3. With an intentionally owned VM directory containing
   `creation-complete` whose contents are exactly `complete`, run `status`.
   Verify that WMI reports the matching `pi-vm-<id>` VM. Run `start` and `stop`
   only on that disposable VM and inspect the WMI return code and final state.
4. Verify that status/start/stop refuse a registered VM when the marker is
   absent or has any other contents.

Native creation is not implemented. In particular, do not infer a safe
`DefineSystem` XML or use a PowerShell cmdlet as a workaround. Before that
scope is expanded, validate the documented Hyper-V WMI classes and async job
result contracts on Windows, then add offline-independent tests and a manual
rollback procedure.
