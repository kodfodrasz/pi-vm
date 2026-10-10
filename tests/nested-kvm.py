#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# ///
"""Run one halt instruction in a nested KVM guest without installing QEMU."""
import ctypes
import fcntl
import mmap
import os
import struct

KVM_GET_API_VERSION = 0xAE00
KVM_CREATE_VM = 0xAE01
KVM_GET_VCPU_MMAP_SIZE = 0xAE04
KVM_SET_USER_MEMORY_REGION = 0x4020AE46
KVM_CREATE_VCPU = 0xAE41
KVM_GET_SREGS = 0x8138AE83
KVM_SET_SREGS = 0x4138AE84
KVM_SET_REGS = 0x4090AE82
KVM_RUN = 0xAE80
KVM_EXIT_HLT = 5


def main():
    kvm = os.open('/dev/kvm', os.O_RDWR)
    vm = None
    vcpu = None
    memory = None
    run_state = None
    try:
        version = fcntl.ioctl(kvm, KVM_GET_API_VERSION, 0)
        if version != 12:
            raise RuntimeError(f'Expected KVM API version 12, got {version}')

        vm = fcntl.ioctl(kvm, KVM_CREATE_VM, 0)
        memory = mmap.mmap(-1, 4096)
        memory[0] = 0xF4  # HLT in real mode
        address = ctypes.addressof(ctypes.c_char.from_buffer(memory))
        region = struct.pack('IIQQQ', 0, 0, 0, 4096, address)
        fcntl.ioctl(vm, KVM_SET_USER_MEMORY_REGION, region)

        vcpu = fcntl.ioctl(vm, KVM_CREATE_VCPU, 0)
        special_registers = bytearray(312)
        fcntl.ioctl(vcpu, KVM_GET_SREGS, special_registers)
        struct.pack_into('Q', special_registers, 0, 0)  # CS base
        struct.pack_into('H', special_registers, 12, 0)  # CS selector
        fcntl.ioctl(vcpu, KVM_SET_SREGS, special_registers)

        registers = [0] * 18
        registers[17] = 2  # Mandatory RFLAGS bit.
        fcntl.ioctl(vcpu, KVM_SET_REGS, struct.pack('18Q', *registers))

        mapping_size = fcntl.ioctl(kvm, KVM_GET_VCPU_MMAP_SIZE, 0)
        run_state = mmap.mmap(vcpu, mapping_size)
        fcntl.ioctl(vcpu, KVM_RUN, 0)
        exit_reason = struct.unpack_from('I', run_state, 8)[0]
        if exit_reason != KVM_EXIT_HLT:
            raise RuntimeError(f'Expected KVM_EXIT_HLT, got {exit_reason}')
    finally:
        if run_state is not None:
            run_state.close()
        if vcpu is not None:
            os.close(vcpu)
        if memory is not None:
            memory.close()
        if vm is not None:
            os.close(vm)
        os.close(kvm)

    print('PASS: nested KVM executed an L2 halt instruction')


if __name__ == '__main__':
    main()
