"""List the source files that went into a build and flag GPL-only ones.

Mediahro ships no GPL code (docs/09 §2). Configure flags alone cannot prove
that (e.g. glslang's Bison parser, lcms2's GPL-3 plugins, FFmpeg's GPL
filters), so every platform build runs this after each library and the
result travels in the archive (build-info/<name>.json → manifest.json).

Compiled sources are read from the build's dependency records:
  * ninja builds (meson, CMake -G Ninja): the recursive inputs of the shipped
    libraries (`ninja -t inputs`) and their objects' header deps (`ninja -t deps`)
  * make builds (autotools, FFmpeg, libvpx): every *.d, *.Po, *.Plo depfile
    (all compiled objects, a superset of what was linked)
  * each depfile's object: its own source (x.c / x.S / x.asm ... at the
    object's path in the source tree). MSVC-style depfiles (-showIncludes, as
    FFmpeg's msvc toolchain writes them) list headers only
  * MSBuild projects (libvpx on Windows): ClCompile / CustomBuild / ClInclude
    items of every .vcxproj
Only files inside the library's source or build tree are classified.

A file is GPL-only when its header carries a GPL notice (or an SPDX GPL id)
with no LGPL wording, no licence exception (Bison, Autoconf, GCC runtime) and
no permissive grant of its own.

Usage: python scripts/source_scan.py [--fallback-tree] NAME SRC_DIR BUILD_DIR OUT_JSON [SHIPPED_LIB ...]
Exits 1 when any GPL-only source was compiled, 2 when the build left no
dependency records. --fallback-tree scans every source file in SRC_DIR
instead (a superset) when there are none.
"""

from __future__ import annotations

import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

GPL = re.compile(r"GNU (?:Affero )?General Public License|SPDX-License-Identifier:\s*\(?\s*A?GPL-", re.I)
LGPL = re.compile(r"GNU (?:Lesser|Library) General Public License|SPDX-License-Identifier:\s*\(?\s*LGPL-", re.I)
EXCEPTION = re.compile(r"special exception|Bison[- ]exception|Autoconf[- ]exception|GCC[- ]exception|"
                       r"WITH\s+[A-Za-z-]+-exception|Classpath[- ]exception", re.I)
PERMISSIVE_ALT = re.compile(r"SPDX-License-Identifier:[^\n]*\b(?:OR)\b", re.I)
# A permissive grant in the file's own header (e.g. valgrind.h: "BSD-style license applies to this
# one file only. The rest of Valgrind is licensed under the GNU General Public License").
PERMISSIVE = re.compile(r"Redistribution and use in source and binary forms|Permission is hereby granted, free of charge|"
                        r"Permission to use, copy, modify, and(?:/or)? distribute this software|"
                        r"SPDX-License-Identifier:\s*(?:MIT|BSD|ISC|Apache|Zlib|0BSD|BSL)", re.I)
SOURCE_EXT = {".c", ".cc", ".cpp", ".cxx", ".c++", ".h", ".hh", ".hpp", ".hxx", ".inc", ".S", ".s", ".asm", ".m", ".mm"}


def ninja(cwd: Path, *args: str) -> list[str]:
    res = subprocess.run(["ninja", "-C", str(cwd), "-t", *args], capture_output=True, text=True,
                         encoding="utf-8", errors="replace")
    return res.stdout.splitlines()


def ninja_sources(build: Path, libs: list[str]) -> set[Path]:
    """Sources (and headers) of the shipped libraries; every compiled source when none is named."""
    out: set[Path] = set()
    if not shutil.which("ninja"):
        return out
    for nf in build.rglob("build.ninja"):
        d = nf.parent
        absolute = lambda s: (Path(s) if Path(s).is_absolute() else d / s)  # noqa: E731
        deps: dict[str, list[str]] = {}
        current = None
        for line in ninja(d, "deps"):
            if line and not line.startswith(" "):
                current = line.split(":", 1)[0]
                deps[current] = []
            elif line.startswith("    ") and current is not None:
                deps[current].append(line.strip())
        targets = [line.split(":", 1)[0] for line in ninja(d, "targets", "all")]
        wanted = [t for t in targets if Path(t).name in libs and not t.endswith(":")]
        # Recursive inputs of the shipped libraries (all targets when no library was named or found).
        inputs = ninja(d, "inputs", *wanted) if wanted else ninja(d, "inputs", "all")
        for item in inputs:
            item = item.strip()
            if Path(item).suffix in SOURCE_EXT:
                out.add(absolute(item))
            for dep in deps.get(item, []):
                out.add(absolute(dep))
    return out


def make_sources(build: Path) -> set[Path]:
    out: set[Path] = set()
    for dep in list(build.rglob("*.d")) + list(build.rglob("*.Po")) + list(build.rglob("*.Plo")) + list(build.rglob("*.Tpo")):
        try:
            text = dep.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        text = text.replace("\\\n", " ")
        for line in text.splitlines():
            if ":" not in line or line.startswith("#"):
                continue
            _, _, deps = line.partition(": ")
            for tok in deps.split():
                p = Path(tok)
                if p.suffix not in SOURCE_EXT:
                    continue
                if p.is_absolute():
                    out.add(p)
                    continue
                # Relative to the directory make ran in: the depfile's directory or an ancestor.
                for base in [dep.parent, *dep.parent.parents]:
                    if (base / p).exists():
                        out.add(base / p)
                        break
                    if base == build:
                        break
    return out


OBJECT_SOURCE_EXT = (".c", ".cc", ".cpp", ".cxx", ".S", ".s", ".asm", ".m", ".mm")


def object_sources(build: Path, src: Path) -> set[Path]:
    """The source each depfile's object was compiled from (MSVC depfiles name only headers)."""
    out: set[Path] = set()
    for dep in build.rglob("*.d"):
        try:
            target = dep.read_text(encoding="utf-8", errors="replace").split(": ", 1)[0].strip()
        except OSError:
            continue
        stems = [dep.relative_to(build).with_suffix("")]
        if target:
            t = Path(target.replace("\\", "/")).with_suffix("")
            if t.is_absolute():
                t = t.relative_to(build) if t.is_relative_to(build) else None
            if t is not None:
                stems.append(t)
        for stem in stems:
            for ext in OBJECT_SOURCE_EXT:
                p = src / (stem.as_posix() + ext)
                if p.exists():
                    out.add(p)
    return out


MSBUILD_ITEM = re.compile(r'<(?:ClCompile|CustomBuild|ClInclude)\s+Include="([^"]+)"')


def msbuild_items(build: Path) -> set[Path]:
    """ClCompile / CustomBuild / ClInclude items of every MSBuild project in the build tree."""
    out: set[Path] = set()
    for proj in build.rglob("*.vcxproj"):
        text = proj.read_text(encoding="utf-8", errors="replace")
        for m in MSBUILD_ITEM.finditer(text):
            p = Path(m.group(1).replace("\\", "/"))
            out.add(p if p.is_absolute() else proj.parent / p)
    return out


def tree_sources(src: Path) -> set[Path]:
    return {p for p in src.rglob("*") if p.is_file() and p.suffix in SOURCE_EXT}


def classify(path: Path) -> str:
    try:
        head = path.read_text(encoding="utf-8", errors="replace")[:8000]
    except OSError:
        return "unreadable"
    if not GPL.search(head):
        return "ok"
    if LGPL.search(head) or EXCEPTION.search(head) or PERMISSIVE_ALT.search(head) or PERMISSIVE.search(head):
        return "exception" if EXCEPTION.search(head) else "ok"
    return "gpl-only"


def main() -> int:
    args = sys.argv[1:]
    fallback_tree = "--fallback-tree" in args
    args = [a for a in args if a != "--fallback-tree"]
    name, src, build, out = args[0], Path(args[1]).resolve(), Path(args[2]).resolve(), Path(args[3])
    libs = [Path(a).name for a in args[4:]]
    found = ninja_sources(build, libs) | make_sources(build) | object_sources(build, src) | msbuild_items(build)
    files = {p.resolve() for p in found if p.exists()}
    files = {p for p in files if p.is_relative_to(src) or p.is_relative_to(build)}
    method = "build records"
    if not files and fallback_tree:
        files, method = tree_sources(src), "whole source tree (no build records)"
    gpl_only, exceptions = [], []
    for p in sorted(files):
        c = classify(p)
        rel = p.relative_to(src).as_posix() if p.is_relative_to(src) else "<build>/" + p.relative_to(build).as_posix()
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
    if not files:
        print(f"source-scan {name}: no dependency records found in {build}", file=sys.stderr)
        return 2
    return 1 if gpl_only else 0


if __name__ == "__main__":
    sys.exit(main())
