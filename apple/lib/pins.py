"""Resolve the Apple source pins from ../versions.json plus apple/pins.json.

versions.json (owned by lane B4a) wins wherever it has a pinned version. The
apple/pins.json overlay fills libraries versions.json has not pinned yet and
adds transitive sub-dependencies. Libraries restricted to other platforms are
dropped; names in BLOCKED (apple/blocked.json) are reported, not built.

Usage:
  pins.py tsv OUT.tsv          name<TAB>version<TAB>sha256<TAB>url<TAB>license
  pins.py versions OUT.json OS merged versions.json for scripts/package.py (OS: ios|macos);
                               apple/flags/*.flags are appended so the manifest
                               records the exact Apple configure flags
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

APPLE = Path(__file__).resolve().parents[1]
ROOT = APPLE.parent


def load() -> tuple[dict, list[dict], dict]:
    versions = json.loads((ROOT / "versions.json").read_text(encoding="utf-8"))
    overlay = json.loads((APPLE / "pins.json").read_text(encoding="utf-8"))["libraries"]
    blocked = json.loads((APPLE / "blocked.json").read_text(encoding="utf-8"))["libraries"]
    return versions, overlay, blocked


def merged() -> tuple[dict, list[dict]]:
    versions, overlay, blocked = load()
    by_name = {o["name"]: o for o in overlay}
    blocked_names = {b["name"] for b in blocked}
    libs, warnings = [], []
    seen = set()
    for lib in versions["libraries"]:
        if "platforms" in lib and "apple" not in lib["platforms"]:
            continue
        lib = dict(lib)
        seen.add(lib["name"])
        o = by_name.get(lib["name"])
        if lib.get("version") and lib.get("sha256"):
            if o and (o["version"], o["sha256"]) != (lib["version"], lib["sha256"]):
                warnings.append(f"{lib['name']}: versions.json pin {lib['version']} overrides apple/pins.json {o['version']}")
        elif o:
            lib["version"], lib["sha256"] = o["version"], o["sha256"]
            if o.get("source"):
                lib["source"] = o["source"]
            lib["pinned_by"] = "apple/pins.json"
        elif not lib.get("optional") and lib["name"] not in blocked_names:
            raise SystemExit(f"pins: {lib['name']} has no version in versions.json or apple/pins.json")
        libs.append(lib)
    for o in overlay:
        if o["name"] not in seen:
            libs.append(dict(o, pinned_by="apple/pins.json"))
    for w in warnings:
        print(f"pins: {w}", file=sys.stderr)
    return versions, libs


def url(lib: dict) -> str:
    v = lib["version"]
    return lib["source"].replace("{version}", v).replace("{series}", ".".join(v.split(".")[:2]))


def main() -> int:
    mode, out = sys.argv[1], Path(sys.argv[2])
    versions, libs = merged()
    _, _, blocked = load()
    if mode == "tsv":
        rows = [
            "\t".join([lib["name"], lib.get("version") or "", lib.get("sha256") or "",
                       url(lib) if lib.get("version") else "", lib["license"]])
            for lib in libs
        ]
        out.write_text("\n".join(rows) + "\n", encoding="utf-8")
    elif mode == "versions":
        names = {b["name"] for b in blocked}
        data = dict(versions)
        # The archive manifest lists only what the archive contains: blocked
        # libraries are left out (they are recorded in apple/blocked.json and STATUS.md §3).
        data["libraries"] = [lib for lib in libs if lib["name"] not in names]
        os_name = sys.argv[3]
        extra = {
            "mpv": ["mpv.apple.flags", f"mpv.{os_name}.flags"],
            "libplacebo": ["libplacebo.apple.flags"],
            "libvips": ["vips.apple.flags"],
        }
        for lib in data["libraries"]:
            if lib["name"] in extra:
                lib["flags"] = list(lib.get("flags", [])) + extra[lib["name"]]
        out.write_text(json.dumps(data, indent=1) + "\n", encoding="utf-8")
    else:
        raise SystemExit(f"pins: unknown mode {mode}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
