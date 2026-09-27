#!/usr/bin/env python3
"""
Synthesize a loadable arm64e slice from the (verified-valid) arm64 slice.

Background: arm64e processes (com.apple.Preferences / OneSettings on iOS 16)
refuse to load arm64-only Mach-Os ("incompatible architecture (have 'arm64',
need 'arm64e')"), and the sbingner clang-10 toolchain's own arm64e output is
broken (chain-encoded objc pointers with no fixup load command -> readClass
SIGBUS). Fix: duplicate the thin arm64 slice, flip its cpusubtype to arm64e
(2) and emit a fat binary containing both. dyld then binds the classic
DYLD_INFO relocations of whichever slice it picks. ldid re-signs afterwards.
"""
import struct
import sys

CPU_TYPE_ARM64 = 0x0100000C
CPU_SUBTYPE_ARM64 = 0
CPU_SUBTYPE_ARM64E = 2
ALIGN = 14  # 16 KB page alignment


def make_fat(path):
    with open(path, 'rb') as f:
        d = f.read()
    if d[:4] == b'\xca\xfe\xba\xbe':
        print(f'{path}: already a fat binary, skip')
        return
    magic = struct.unpack_from('<I', d, 0)[0]
    if magic != 0xFEEDFACF:
        raise SystemExit(f'{path}: not a 64-bit Mach-O (magic {magic:#x})')
    cputype, cpusub, filetype = struct.unpack_from('<iiI', d, 4)
    if cputype != CPU_TYPE_ARM64 or filetype != 6:
        raise SystemExit(f'{path}: unexpected cputype {cputype:#x} filetype {filetype:#x}')

    ps = 1 << ALIGN
    off0 = ps
    off1 = (off0 + len(d) + ps - 1) & ~(ps - 1)

    arm64e = bytearray(d)
    struct.pack_into('<I', arm64e, 8, CPU_SUBTYPE_ARM64E)

    out = bytearray(struct.pack('>II', 0xCAFEBABE, 2))
    out += struct.pack('>iiIII', cputype, CPU_SUBTYPE_ARM64, off0, len(d), ALIGN)
    out += struct.pack('>iiIII', cputype, CPU_SUBTYPE_ARM64E, off1, len(arm64e), ALIGN)
    out += b'\x00' * (off0 - len(out))
    out += d
    out += b'\x00' * (off1 - len(out))
    out += arm64e

    with open(path, 'wb') as f:
        f.write(bytes(out))
    print(f'{path}: wrote fat (arm64 @{off0:#x}, arm64e @{off1:#x}, total {len(out)} bytes)')


for p in sys.argv[1:]:
    make_fat(p)
