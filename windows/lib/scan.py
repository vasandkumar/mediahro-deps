"""Windows front end for scripts/source_scan.py (lane B4a): same classifier,
same JSON, plus the compile records Windows builds leave:

  * ninja builds (meson, CMake): exactly as source_scan.py
  * FFmpeg's msvc toolchain: its depfiles come from -showIncludes and list
    only headers, so each object's own source (x.c / x.S / x.asm next to the
    object's path in the source tree) is added
  * MSBuild projects (libvpx): ClCompile / CustomBuild items of the .vcxproj
  * no records at all: every source file in the tree (a superset)

Usage: python scan.py NAME SRC_DIR BUILD_DIR OUT_JSON [SHIPPED_LIB ...]
Exits 1 when any GPL-only source was compiled.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
import source_scan as ss  # noqa: E402


def msvc_make_objects(build: Path, src: Path) -> set[Path]:
    out: set[Path] = set()
    for dep in build.rglob("*.d"):
        try:
            first = dep.read_text(encoding="utf-8", errors="replace").split(":", 1)[0].strip()
        except OSError:
            continue
        rel = dep.relative_to(build).with_suffix("")
        for cand in (first, rel.as_posix()):
            stem = Path(cand).with_suffix("")
            for ext in (".c", ".S", ".asm", ".cpp", ".m"):
                p = src / (stem.as_posix() + ext)
                if p.exists():
                    out.add(p)
    return out


def msbuild_items(build: Path) -> set[Path]:
    out: set[Path] = set()
    item = re.compile(r'<(?:ClCompile|CustomBuild|ClInclude)\s+Include="([^"]+)"')
    for proj in build.rglob("*.vcxproj"):
        text = proj.read_text(encoding="utf-8", errors="replace")
        for m in item.finditer(text):
            p = Path(m.group(1).replace("\\", "/"))
            p = p if p.is_absolute() else proj.parent / p
            out.add(p)
    return out


def all_sources(src: Path) -> set[Path]:
    return {p for p in src.rglob("*") if p.is_file() and p.suffix in ss.SOURCE_EXT}


def main() -> int:
    name, src, build, out = sys.argv[1], Path(sys.argv[2]).resolve(), Path(sys.argv[3]).resolve(), Path(sys.argv[4])
    libs = [Path(a).name for a in sys.argv[5:]]
    found = ss.ninja_sources(build, libs) | ss.make_sources(build) | msvc_make_objects(build, src) | msbuild_items(build)
    files = {p.resolve() for p in found if p.exists()}
    files = {p for p in files if p.is_relative_to(src) or p.is_relative_to(build)}
    method = "build records"
    if not files:
        files = all_sources(src)
        method = "whole source tree (no compile records)"
    gpl_only, exceptions = [], []
    for p in sorted(files):
        c = ss.classify(p)
        rel = (p.relative_to(src) if p.is_relative_to(src) else Path("<build>") / p.relative_to(build)).as_posix()
        if c == "gpl-only":
            gpl_only.append(rel)
        elif c == "exception":
            exceptions.append(rel)
    result = {"library": name, "files_scanned": len(files), "gpl_only_sources": gpl_only,
              "gpl_with_exception_sources": exceptions}
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(f"source-scan {name}: {len(files)} files ({method}), {len(gpl_only)} GPL-only, {len(exceptions)} GPL-with-exception")
    for f in gpl_only:
        print(f"  GPL-only: {f}", file=sys.stderr)
    return 1 if gpl_only else 0


if __name__ == "__main__":
    sys.exit(main())
