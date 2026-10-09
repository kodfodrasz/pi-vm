# Validation notes

Tested on 8 October 2026 (UTC), on this Linux host inside Hyper-V.
The host exposes AMD-V and `/dev/kvm`; the host KVM nested setting is on.

## Results

| Check | Result |
| --- | --- |
| Fedora 44-1.7 compressed raw image SHA-256 | Pass |
| Expanded 5 GiB raw image size and SHA-256 | Pass |
| Raw image with NoCloud ISO on KVM, BIOS boot | Pass |
| Raw image with NoCloud ISO on KVM, UEFI boot | Pass, OVMF test |
| Fresh 1 CPU / 1024 MiB / 8 GiB guest bootstrap | Pass |
| Default 2 CPU / 2048 MiB / 16 GiB guest bootstrap | Pass |
| Root partition and filesystem fill the disk | Pass, about 7.9 GiB and 16 GiB roots |
| `pi` user, fish login, hostname `pipette` | Pass |
| Pi 1.1.0, Starship 1.26.0 | Pass |
| Initial public-key login and password login off | Pass |
| SELinux enforcing | Pass |
| Rootless Podman info and user namespace | Pass |
| Actual rootless Alpine container execution | Pass |
| Hyper-V balloon, network, storage and bus kernel modules available | Pass |
| Vim, tmux, fish config and Pi completion loading | Pass |
| No guest QEMU or libvirt packages | Pass |
| Virtio balloon: 1 GiB to 768 MiB, then restored | Pass, QMP queried actual size |
| Nested KVM executes an L2 halt instruction | Pass, Python KVM ioctl test |
| Graceful stop and restart preserve the disk | Pass |
| Reusable `make validate` with nested and balloon options | Pass on running `pipette` |
| Real wrong-port validation against a second VM | Correctly rejected by instance ID |
| Validator negative checks and balloon restoration unit tests | Pass, 20 tests |
| KVM process identity, PID handles, and input guards | Pass, 17 offline tests |
| Below-source KVM disk size rejected before instance creation | Pass |
| Seed ISO label and root files | Pass, `CIDATA`, `user-data`, `meta-data` |
| UTF-8 BOM / CRLF source normalization | Pass, identical Linux seed output |
| PowerShell syntax and ISO C# stream helper compilation | Pass on Linux |
| Fixed VHD footer, QEMU recognition, raw/VHD content match | Pass, small and 5 GiB cases |
| Offline Hyper-V orchestration and failure recovery | Pass, 25 isolated mock cases |
| Windows IMAPI2FS ISO creation | Not tested; needs Windows |
| Windows 11 Hyper-V base/child creation and deployment | Not tested; needs Windows |
| Hyper-V memory reclamation inside the new guest | Not tested; needs Windows |

The first boot may show `extended_status: degraded done` with recoverable hostname
warnings. Fedora cloud-init tries `hostnamectl` before the system bus exists.
Bootstrap sets the hostname later, the schema passes, and `errors` is empty.
After a normal restart, the deployed guest reports `extended_status: done`, no
errors, and no recoverable warnings. Do not ignore other warnings or missing
bootstrap markers.

## Current deployment

`pipette` is running with 2 CPUs, 2048 MiB RAM, and a 16 GiB disk.
Only this project's deployed VM was left running. The small test guests are
stopped; their disks and logs remain in `build/`. External raw/UEFI probe files
remain in `~/.cache/pi-vm/probe/`, with that probe stopped.

```sh
ssh -p 2222 pi@127.0.0.1
make kvm-status INSTANCE=pipette
make kvm-stop INSTANCE=pipette
make kvm-start INSTANCE=pipette
```

The runtime checks used a private test known-hosts file at
`~/.cache/pi-vm/host/pipette-known-hosts`. If you have an old key for port 2222,
use that file explicitly rather than disabling SSH host-key checks:

```sh
ssh -o UserKnownHostsFile="$HOME/.cache/pi-vm/host/pipette-known-hosts" \
    -p 2222 pi@127.0.0.1
```

Main logs are `build/host-tests.log`, `build/final-runtime.log`,
`build/pipette-runtime.log`, and each VM's `serial.log`/`qemu.log`.
The clean post-restart status is in `~/.cache/pi-vm/host/pipette-reboot.log`.
These local logs are not tracked by Git.

## Repeat the tests

Run `make test`. Large test scratch files use `build/test-tmp`, not `/tmp`.
The optional 5 GiB VHD test needs about 11 GiB free. Do not report it as passed
if it was skipped for missing tools or space.

For a fresh guest test, use a new instance ID and an unused SSH port:

```sh
./scripts/kvm.sh start check-001 --cpus 1 --memory 1024 --disk 8G --ssh-port 2223
ssh -p 2223 pi@127.0.0.1
# Inside the guest:
sudo cloud-init status --long
sudo cloud-init schema --system
test -f /var/lib/pi-vm/bootstrap-complete
```

To test actual nested KVM without guest QEMU packages, run from the host:

```sh
ssh -p 2223 pi@127.0.0.1 'sudo modprobe kvm_amd; sudo python3 -' \
    < tests/nested-kvm.py
```

Use `kvm_intel` instead of `kvm_amd` on an Intel host. The test maps one page,
creates an L2 VM and VCPU through `/dev/kvm`, runs a halt instruction, and checks
for `KVM_EXIT_HLT`. A CPU flag alone is not accepted as proof of nested execution.

The reusable Pi skill is `.agents/skills/validate-pi-vm/SKILL.md`. It covers
storage limits, fresh boot tests, balloon checks, shutdown, and Windows caveats.

## Review

Luna agents handled local scouting and bounded coding work. A Terra reviewer
found the initial Hyper-V temporary-file extension and minimum-size issues.
Those were fixed. The recheck returned **OK with notes**, with no remaining P1
blocker. Its outdated disk-unit documentation note is fixed. Its seed-failure
note is also fixed: new KVM instances now build the ISO before the overlay,
and seed publication is atomic. Tests were rerun afterward.

## Windows hardening pass

A later Terra review found four blockers in the first hardening draft: a
PowerShell 7-only file API, unsafe cleanup after failed VM removal, insufficient
shared-volume space accounting, and a broken test mock. The parent fixed these.
Automatic seed creation is also back inside the build lock.

`tests/hyperv.ps1` loads an isolated fake Hyper-V module. Production has no
mock-mode environment switch. No real Hyper-V operation or network request runs
in those tests. They cover first creation, base reuse, static/dynamic memory,
preflight failures, retries after conversion/configuration/start errors, and
retaining disks after uncertain registration or failed removal/stop/lookup.
Staged raw replacement and failed-download cleanup are tested too.

Terra rechecked the fixed Windows seam and found no issues. Its verdict is
**OK with notes**, with real Windows runtime tests still open.

The mocks do not prove that Windows cmdlets or IMAPI2FS work. Those manual
checks remain open. The deployed KVM VM stayed running during this pass.
Further guest checks passed: a real rootless Alpine container and another
balloon resize, from 2 GiB to 1.75 GiB, followed by restoration to 2 GiB.
Logs are `build/hyperv-mock.log` and `~/.cache/pi-vm/host/hardening-guest.log`.

## KVM process safety

The first worker timed out and its resume was stopped. Partial changes were
saved in `build/agent-recovery/`. The parent finished the bounded fix directly.

The launcher now checks the process executable and the exact `-drive` file
argument. An unrelated process with QEMU words in its arguments is not enough.
A `.qcow2.backup` suffix or duplicate file option does not match. PID files
must be small regular files, not symlinks or pipes.

Forced stop pins a Linux PID handle before rechecking identity. It sends TERM
through that handle, not a reusable PID number. Missing API support, a process
that has exited, or an identity mismatch fails without an unsafe fallback.
Tests cover handle order and cleanup. One real test-owned Python process
survives status and forced-stop checks despite having the old matching words
in its arguments. Another test-owned process verifies native PID-handle TERM.
No test starts or stops a real VM.

Resource validation is bounded and decimal. Invalid actions, missing values,
size overflow, and comma-containing build paths fail before creating storage.
The active-instance check also runs before downloads. The Makefile discovers
only the two unit-test modules and keeps their scratch files on disk; it does
not accidentally import the footer integration script a second time.

A bounded fresh-context Terra review returned **OK**, with no issues found.
The full host suite and `make validate` passed. Logs are
`build/kvm-safety-host-tests.log` and `build/kvm-safety-runtime.log`.
`pipette` kept its original PID 355892 and was never stopped or restarted.

## Reusable guest validator

The parent completed `scripts/validate.py` after its worker handoff. Its full
run against `pipette` passed with both `--nested` and `--balloon`. The JSON result
is `build/pipette/validation.json`; the command log is `build/runtime-validation.log`.
A real second guest on port 2223 was correctly rejected when validating
`pipette`; the result is in `build/validator-wrong-port.log`. That guest was
stopped afterward.
The VM's original 2 GiB memory target was restored and confirmed.

The validator checks the real `/var/lib/pi-vm/bootstrap-complete` marker. It does
not mistake cloud-init's generic boot-finished file for a successful install.
Instance ID and hostname are separate; both are checked. It fails on missing metadata, wrong
versions, failed root growth, password login, and unexpected cloud-init errors.

A negative test showed that tmux can return success despite an invalid startup
config. The validator now starts with no config, then explicitly uses
`source-file`, which returns a failing code for the invalid config. Its private
test server is always removed. A regression test covers this behavior. Another
test covers the short interval between the success marker and cloud-final
finishing, so a fresh boot keeps waiting rather than failing too early.

Further validator fixes evaluate SSH `Match` rules for the actual connection,
accept only the exact known hostname warning, and confirm that the temporary
tmux server is gone. Tests cover enabled password login under a user/address
rule, warning suffixes, failed cleanup, and exact root-growth arithmetic.
Terra's final bounded validator recheck returned **OK**, with no issues found.

Normal OpenSSH authentication can use the caller's agent or identity files;
the validator does not inspect, copy, or include private key material in reports.

Windows checkouts also keep LF through `.gitattributes`. The renderer explicitly
reads UTF-8 text, removes BOMs, normalizes CRLF, and writes LF seed files. A test
converts every source asset and template to BOM/CRLF form and confirms identical
rendered bytes. This prevents a Windows carriage return from breaking the Linux
bootstrap shebang.

The Windows test checklist is `hyperv-manual-test.md`. It lists the checks that
still need a real Windows 11 host.

A first reviewer process failed before returning a result. It was retried
through the same subagent system; that failed run was not counted as a review.
