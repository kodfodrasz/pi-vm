#!/usr/bin/env python3
"""Run one halt instruction in a nested KVM guest, with no QEMU install.

Run inside the test VM as root. This is a diagnostic, not guest software.
"""
import ctypes
import fcntl
import mmap
import os
import struct

kvm = os.open('/dev/kvm', os.O_RDWR)
assert fcntl.ioctl(kvm, 0xAE00, 0) == 12, 'KVM API mismatch'
vm = fcntl.ioctl(kvm, 0xAE01, 0)
memory = mmap.mmap(-1, 4096)
memory[0] = 0xF4  # HLT in real mode
address = ctypes.addressof(ctypes.c_char.from_buffer(memory))
fcntl.ioctl(vm, 0x4020AE46, struct.pack('IIQQQ', 0, 0, 0, 4096, address))
vcpu = fcntl.ioctl(vm, 0xAE41, 0)
sregs = bytearray(312)
fcntl.ioctl(vcpu, 0x8138AE83, sregs)
struct.pack_into('Q', sregs, 0, 0)  # CS base
struct.pack_into('H', sregs, 12, 0)  # CS selector
fcntl.ioctl(vcpu, 0x4138AE84, sregs)
regs = [0] * 18
regs[17] = 2  # mandatory RFLAGS bit
fcntl.ioctl(vcpu, 0x4090AE82, struct.pack('18Q', *regs))
run = mmap.mmap(vcpu, fcntl.ioctl(kvm, 0xAE04, 0))
fcntl.ioctl(vcpu, 0xAE80, 0)
reason = struct.unpack_from('I', run, 8)[0]
assert reason == 5, f'Expected KVM_EXIT_HLT, got {reason}'
print('PASS: nested KVM executed an L2 halt instruction')
