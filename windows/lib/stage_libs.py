"""Copy the import libraries for the staged DLLs into the archive's lib/.

An import library is an ar archive whose members include short import objects
(IMPORT_OBJECT_HEADER: Sig1 0x0000, Sig2 0xFFFF). It is kept when every DLL it
names is in bin/ or is vulkan-1.dll (linked, delay-loaded, driver-provided).
Static archives of build-internal pieces (glslang.lib, SPIRV-Tools.lib, ...)
have no import objects and are left out.

Usage: python stage_libs.py PREFIX_LIB STAGE_LIB STAGE_BIN
"""

from __future__ import annotations

import shutil
import sys
from pathlib import Path

EXTRA = {"vulkan-1.dll"}
# Import libraries of DLLs deliberately left out of bin/ (see stage.sh).
UNSHIPPED = {"spirv-tools-shared.dll"}


def import_dlls(lib: Path) -> set[str]:
    """DLL names of the short import objects among the archive members."""
    names: set[str] = set()
    with open(lib, "rb") as f:
        if f.read(8) != b"!<arch>\n":
            return names
        while True:
            hdr = f.read(60)
            if len(hdr) < 60:
                break
            try:
                size = int(hdr[48:58].decode("ascii").strip())
            except ValueError:
                break
            start = f.tell()
            head = f.read(min(size, 20))
            if len(head) == 20 and head[:4] == b"\x00\x00\xff\xff":
                rest = f.read(min(size - 20, 1024))
                parts = rest.split(b"\x00")
                if len(parts) >= 2 and parts[1].lower().endswith(b".dll"):
                    names.add(parts[1].decode("ascii", "replace").lower())
            f.seek(start + size + (size & 1))
    return names


def main() -> int:
    src, dst, bindir = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
    dlls = {p.name.lower() for p in bindir.glob("*.dll")} | EXTRA
    kept = skipped = 0
    errors = []
    for lib in sorted(src.glob("*.lib")):
        refs = import_dlls(lib)
        if not refs or refs <= UNSHIPPED:
            skipped += 1
        elif refs <= dlls:
            shutil.copy2(lib, dst / lib.name)
            kept += 1
        else:
            errors.append(f"{lib.name} imports from {', '.join(sorted(refs - dlls))}, which is not in bin/")
    for e in errors:
        print(f"stage_libs: {e}", file=sys.stderr)
    print(f"stage_libs: {kept} import libraries staged, {skipped} static or unshipped libraries skipped")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
