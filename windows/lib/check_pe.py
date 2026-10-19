"""Verify every DLL staged for a Windows archive.

Fails unless each PE:
  - targets the expected machine (x64 / arm64),
  - has DYNAMICBASE, HIGHENTROPYVA, NXCOMPAT and GUARD_CF set and a CFG
    function table in its load config (built with /guard:cf),
  - imports only Windows system DLLs, the MSVC runtime, or DLLs in the archive,
    and links vulkan-1.dll (driver-provided) only as a delay-load import,
  - does not carry a banned library name (OpenSSL, libheif/libde265, GPL codecs).

Usage: python check_pe.py ARCH BIN_DIR
"""

from __future__ import annotations

import re
import struct
import sys
from pathlib import Path

MACHINE = {"x64": 0x8664, "arm64": 0xAA64}
DYNAMIC_BASE, HIGH_ENTROPY_VA, NX_COMPAT, GUARD_CF = 0x0040, 0x0020, 0x0100, 0x4000
CF_INSTRUMENTED, CF_FUNCTION_TABLE_PRESENT = 0x100, 0x400

# Loaded from the OS (or the driver for vulkan-1.dll, delay-loaded) or the
# MSVC 2015-2022 redistributable the Flutter runner already ships.
SYSTEM = re.compile(
    r"^(api-ms-win-.*|ext-ms-win-.*|kernel32|kernelbase|user32|gdi32|advapi32|shell32|shlwapi|ole32|oleaut32|"
    r"ws2_32|wsock32|iphlpapi|dnsapi|secur32|crypt32|bcrypt|ncrypt|cfgmgr32|setupapi|winmm|avrt|mfplat|mf|mfuuid|"
    r"mfreadwrite|propsys|dxgi|d3d11|d3d12|d3d9|dxva2|dcomp|dwrite|d2d1|usp10|version|psapi|dbghelp|ntdll|"
    r"rpcrt4|userenv|netapi32|mpr|imm32|comctl32|comdlg32|uxtheme|dwmapi|winhttp|wininet|normaliz|wldap32|"
    r"vulkan-1|opengl32|ucrtbase|vcruntime140|vcruntime140_1|msvcp140|msvcp140_1|msvcp140_2|concrt140|vcomp140)\.dll$",
    re.I,
)
# Present only where a GPU driver installed it: never a hard import.
DELAY_ONLY = {"vulkan-1.dll"}
BANNED = re.compile(r"(libssl|libcrypto|ssleay|libeay|openssl|heif|de265|x264|x265|rubberband|dvdcss|dvdnav|dvdread|postproc|smbclient|cdio|frei0r)", re.I)


def rva_to_off(sections, rva):
    for va, vsz, raw, rsz in sections:
        if va <= rva < va + max(vsz, rsz):
            return rva - va + raw
    return None


def inspect(path: Path):
    d = path.read_bytes()
    pe = struct.unpack_from("<I", d, 0x3C)[0]
    if d[pe:pe + 4] != b"PE\0\0":
        raise ValueError("not a PE file")
    machine, nsec = struct.unpack_from("<HH", d, pe + 4)
    opt_size = struct.unpack_from("<H", d, pe + 20)[0]
    opt = pe + 24
    if struct.unpack_from("<H", d, opt)[0] != 0x20B:
        raise ValueError("not PE32+")
    dllchar = struct.unpack_from("<H", d, opt + 70)[0]
    ndirs = struct.unpack_from("<I", d, opt + 108)[0]
    dirs = [struct.unpack_from("<II", d, opt + 112 + 8 * i) for i in range(ndirs)]
    sec_off = opt + opt_size
    sections = []
    for i in range(nsec):
        vsz, va, rsz, raw = struct.unpack_from("<IIII", d, sec_off + 40 * i + 8)
        sections.append((va, vsz, raw, rsz))
    imports, delayed = [], []
    for idx in (1, 13):  # import table, delay-import table
        if idx >= ndirs or not dirs[idx][0]:
            continue
        off = rva_to_off(sections, dirs[idx][0])
        step, name_at = (20, 12) if idx == 1 else (32, 4)
        while off is not None:
            name_rva = struct.unpack_from("<I", d, off + name_at)[0]
            if not name_rva:
                break
            no = rva_to_off(sections, name_rva)
            (imports if idx == 1 else delayed).append(d[no:d.index(b"\0", no)].decode("ascii", "replace"))
            off += step
    guard = 0
    if ndirs > 10 and dirs[10][0]:
        lc = rva_to_off(sections, dirs[10][0])
        size = struct.unpack_from("<I", d, lc)[0]
        if size >= 0x94:  # GuardFlags at 0x90 in IMAGE_LOAD_CONFIG_DIRECTORY64
            guard = struct.unpack_from("<I", d, lc + 0x90)[0]
    return machine, dllchar, guard, imports, delayed


def main() -> int:
    arch, bindir = sys.argv[1], Path(sys.argv[2])
    dlls = sorted(bindir.glob("*.dll")) + sorted(bindir.glob("*.exe"))
    local = {p.name.lower() for p in dlls}
    errors = []
    for p in dlls:
        try:
            machine, dllchar, guard, imports, delayed = inspect(p)
        except (ValueError, struct.error) as e:
            errors.append(f"{p.name}: {e}")
            continue
        if machine != MACHINE[arch]:
            errors.append(f"{p.name}: machine 0x{machine:04x}, expected {arch}")
        for bit, name in ((DYNAMIC_BASE, "DYNAMICBASE"), (HIGH_ENTROPY_VA, "HIGHENTROPYVA"), (NX_COMPAT, "NXCOMPAT"), (GUARD_CF, "GUARD_CF")):
            if not dllchar & bit:
                errors.append(f"{p.name}: missing {name}")
        if not (guard & CF_INSTRUMENTED and guard & CF_FUNCTION_TABLE_PRESENT):
            errors.append(f"{p.name}: no CFG function table (GuardFlags 0x{guard:x}); not linked with /guard:cf")
        if BANNED.search(p.name):
            errors.append(f"{p.name}: banned library")
        for imp in imports:
            if imp.lower() in DELAY_ONLY:
                errors.append(f"{p.name}: imports {imp} directly; it must be delay-loaded (/DELAYLOAD)")
        for imp in imports + delayed:
            if BANNED.search(imp):
                errors.append(f"{p.name}: imports banned {imp}")
            elif imp.lower() not in local and not SYSTEM.match(imp):
                errors.append(f"{p.name}: imports {imp}, which is neither a system DLL nor in the archive")
        print(f"check_pe: {p.name}: ok" if not any(e.startswith(p.name + ":") for e in errors) else f"check_pe: {p.name}: FAIL")
    for e in errors:
        print(f"check_pe: {e}", file=sys.stderr)
    print(f"check_pe: {len(dlls)} files, {len(errors)} errors")
    return 1 if errors or not dlls else 0


if __name__ == "__main__":
    sys.exit(main())
