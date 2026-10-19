"""Copy the import libraries for the staged DLLs into the archive's lib/.

An import library (short-import COFF archive members) is kept when the DLL it
names is in bin/ or is vulkan-1.dll (linked, delay-loaded, driver-provided).
Static archives of build-internal pieces (glslang.lib, SPIRV-Tools.lib, ...)
are left out.

Usage: python stage_libs.py PREFIX_LIB STAGE_LIB STAGE_BIN
"""

from __future__ import annotations

import re
import shutil
import sys
from pathlib import Path

EXTRA = {"vulkan-1.dll"}


def import_dlls(lib: Path) -> set[str]:
    """DLL names referenced by short import objects (sig 0x0000 0xFFFF)."""
    data = lib.read_bytes()
    if not data.startswith(b"!<arch>\n"):
        return set()
    names = set()
    for m in re.finditer(rb"\x00\x00\xff\xff", data):
        hdr = data[m.start():m.start() + 20]
        if len(hdr) < 20:
            continue
        size = int.from_bytes(hdr[12:16], "little")
        body = data[m.start() + 20:m.start() + 20 + size]
        parts = body.split(b"\x00")
        if len(parts) >= 2 and parts[1].lower().endswith(b".dll"):
            names.add(parts[1].decode("ascii", "replace").lower())
    return names


def main() -> int:
    src, dst, bindir = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
    dlls = {p.name.lower() for p in bindir.glob("*.dll")} | EXTRA
    kept = skipped = 0
    for lib in sorted(src.glob("*.lib")):
        refs = import_dlls(lib)
        if refs and refs <= dlls:
            shutil.copy2(lib, dst / lib.name)
            kept += 1
        else:
            skipped += 1
    print(f"stage_libs: {kept} import libraries staged, {skipped} static or foreign libraries skipped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
