"""Ship only what the app links or loads (ADR-020).

prune: keep the DLLs matching the root patterns (what Mediahro opens itself:
the FFI libraries, libmpv, the FFmpeg libraries B1 remuxes with, the ggml CPU
variants ggml loads at run time) and everything they import or delay-load,
transitively; delete the rest from BIN_DIR and list them in UNSHIPPED_OUT.
Every pattern must match a DLL, so a renamed library fails the build instead
of disappearing from the archive.

info: rewrite STAGE/build-info/*.json so "files" lists what the archive holds
(bin/, lib/) and "not_shipped" what the build produced but left out.

Usage: python ship.py prune BIN_DIR UNSHIPPED_OUT PATTERN...
       python ship.py info STAGE_DIR
"""

from __future__ import annotations

import fnmatch
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from check_pe import inspect  # noqa: E402


def prune(bindir: Path, out: Path, patterns: list[str]) -> int:
    dlls = {p.name.lower(): p for p in bindir.glob("*.dll")}
    keep: set[str] = set()
    todo: list[str] = []
    for pat in patterns:
        hits = [n for n in dlls if fnmatch.fnmatch(n, pat.lower())]
        if not hits:
            print(f"ship: no DLL matches {pat}", file=sys.stderr)
            return 1
        todo += hits
    while todo:
        n = todo.pop()
        if n in keep:
            continue
        keep.add(n)
        _, _, _, imports, delayed = inspect(dlls[n])
        todo += [i.lower() for i in imports + delayed if i.lower() in dlls]
    gone = sorted(set(dlls) - keep)
    for n in gone:
        dlls[n].unlink()
    out.write_text("".join(f"{n}\n" for n in gone), encoding="utf-8")
    size = sum(p.stat().st_size for n, p in dlls.items() if n in keep)
    print(f"ship: {len(keep)} DLLs shipped ({size / 2**20:.1f} MiB), {len(gone)} not shipped: {' '.join(gone)}")
    return 0


def info(stage: Path) -> int:
    held = {p.name.lower() for d in ("bin", "lib") for p in (stage / d).glob("*") if p.is_file()}
    for p in sorted((stage / "build-info").glob("*.json")):
        d = json.loads(p.read_text(encoding="utf-8"))
        files = d.get("files", [])
        gone = [f for f in files if f.lower() not in held]
        if gone:
            d["files"] = [f for f in files if f.lower() in held]
            d["not_shipped"] = sorted(set(d.get("not_shipped", [])) | set(gone))
            p.write_text(json.dumps(d, indent=2), encoding="utf-8")
    return 0


if __name__ == "__main__":
    if sys.argv[1] == "prune":
        sys.exit(prune(Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4:]))
    sys.exit(info(Path(sys.argv[2])))
