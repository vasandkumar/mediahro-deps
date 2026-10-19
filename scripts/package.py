"""Package one target's build output into a release archive.

Archive layout:  lib/  include/  licenses/<name>.txt  manifest.json
manifest.json feeds Mediahro's tools/licence_scan:
  {"target": "...", "artefacts": [{"name","version","license","linking","configure":[...]}]}
Prints the SHA-256 that goes into the app's deps.lock.

Usage: python scripts/package.py TARGET STAGING_DIR OUT_DIR
"""

from __future__ import annotations

import hashlib
import json
import sys
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def flags_for(lib: dict, platform: str) -> list[str]:
    out: list[str] = []
    for name in lib.get("flags", []):
        f = ROOT / "flags" / name.replace("{platform}", platform)
        if f.exists():
            out += [
                line.strip()
                for line in f.read_text(encoding="utf-8").splitlines()
                if line.strip() and not line.lstrip().startswith("#")
            ]
    return out


def main() -> int:
    target, staging, out_dir = sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3])
    platform = target.split("-")[0]
    platform = "apple" if platform in ("ios", "macos") else platform
    data = json.loads((ROOT / "versions.json").read_text(encoding="utf-8"))
    artefacts = []
    for lib in data["libraries"]:
        if "platforms" in lib and platform not in lib["platforms"]:
            continue
        if not lib.get("version"):
            if lib.get("optional"):
                continue
            print(f"package: {lib['name']} has no pinned version", file=sys.stderr)
            return 1
        artefacts.append({
            "name": lib["name"],
            "version": lib["version"],
            "license": lib["license"],
            "linking": "dynamic" if lib["linking"] == "dynamic" else "static-or-dynamic",
            "configure": flags_for(lib, platform),
        })
    manifest = {"target": target, "artefacts": artefacts}
    (staging / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    out_dir.mkdir(parents=True, exist_ok=True)
    archive = out_dir / f"mediahro-deps-{target}.tar.gz"
    with tarfile.open(archive, "w:gz") as tf:
        for p in sorted(staging.rglob("*")):
            tf.add(p, arcname=p.relative_to(staging), recursive=False)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (out_dir / f"{archive.name}.sha256").write_text(f"{digest}  {archive.name}\n")
    print(f"{target} {digest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
