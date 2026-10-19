"""Package one target's build output into a release archive.

Archive layout:  lib/  include/  licenses/<name>.txt  build-info/<name>.json  manifest.json
(platform builds may add bin/ etc.). manifest.json feeds Mediahro's tools/licence_scan:

  {"target": "...", "mediahro_deps": {"commit", "release"},
   "artefacts": [{"name", "version", "license", "linking", "configure": [...],
                  "source": {"url", "sha256"}, "files": [...], "compiled_into",
                  "files_scanned", "gpl_only_sources": [...], "gpl_with_exception_sources": [...]}],
   "not_built": [{"name", "reason"}]}

When the staging tree has build-info/ (written by the platform build for each
library it actually built), the manifest lists exactly those libraries with
their real configure arguments and source-scan results, and every library of
the platform that was not built is listed under "not_built". Without
build-info/ the manifest falls back to every library of the platform with the
flags from flags/.

Prints the SHA-256 that goes into the app's deps.lock and writes
<archive>.sha256 next to the archive.

Usage: python scripts/package.py TARGET STAGING_DIR OUT_DIR
"""

from __future__ import annotations

import gzip
import hashlib
import io
import json
import os
import subprocess
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


def source_of(lib: dict) -> dict:
    url = lib["source"]
    for key in ("version", "tag", "series", "commit"):
        if lib.get(key):
            url = url.replace("{" + key + "}", str(lib[key]))
    src = {"url": url, "sha256": lib.get("sha256")}
    patches = sorted((ROOT / "patches" / lib["name"]).glob("*.patch"))
    if patches:
        src["patches"] = [{"file": p.relative_to(ROOT).as_posix(), "sha256": hashlib.sha256(p.read_bytes()).hexdigest()}
                          for p in patches]
    if lib.get("commit"):
        src["commit"] = lib["commit"]
    return src


def git_commit() -> str | None:
    try:
        return subprocess.run(["git", "-C", str(ROOT), "rev-parse", "HEAD"], capture_output=True, text=True,
                              check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return None


def reproducible_tar(staging: Path, archive: Path) -> None:
    """Sorted entries, fixed owner and mtime, so a rebuild of the same inputs packs identically."""
    mtime = int(os.environ.get("SOURCE_DATE_EPOCH", "1767225600"))
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w", format=tarfile.PAX_FORMAT) as tf:
        for p in sorted(staging.rglob("*")):
            info = tf.gettarinfo(str(p), arcname=p.relative_to(staging).as_posix())
            info.uid = info.gid = 0
            info.uname = info.gname = ""
            info.mtime = mtime
            if info.isreg():
                info.mode = 0o755 if os.access(p, os.X_OK) or p.suffix in (".so", ".dll", ".dylib") else 0o644
                with open(p, "rb") as f:
                    tf.addfile(info, f)
            else:
                tf.addfile(info)
    with open(archive, "wb") as out, gzip.GzipFile(filename="", mode="wb", fileobj=out, mtime=mtime) as gz:
        gz.write(raw.getvalue())


def main() -> int:
    target, staging, out_dir = sys.argv[1], Path(sys.argv[2]), Path(sys.argv[3])
    platform = target.split("-")[0]
    platform = "apple" if platform in ("ios", "macos") else platform
    data = json.loads((ROOT / "versions.json").read_text(encoding="utf-8"))
    info_dir = staging / "build-info"
    built = {p.stem: json.loads(p.read_text(encoding="utf-8")) for p in info_dir.glob("*.json")} if info_dir.is_dir() else None
    artefacts, not_built = [], []
    for lib in data["libraries"]:
        if "platforms" in lib and platform not in lib["platforms"]:
            continue
        if built is not None and lib["name"] not in built:
            not_built.append({"name": lib["name"], "reason": "not built for this target (see STATUS.md §3)"})
            continue
        if not lib.get("version"):
            if lib.get("optional"):
                continue
            print(f"package: {lib['name']} has no pinned version", file=sys.stderr)
            return 1
        entry = {
            "name": lib["name"],
            "version": lib["version"],
            "license": lib["license"],
            "linking": {"dynamic": "dynamic", "build": "build-only"}.get(lib["linking"], "static-or-dynamic"),
            "source": source_of(lib),
            "configure": flags_for(lib, platform),
        }
        if built is not None:
            b = built[lib["name"]]
            entry["configure"] = b.get("configure", [])
            for key in ("files", "compiled_into", "files_scanned", "gpl_only_sources", "gpl_with_exception_sources"):
                if key in b:
                    entry[key] = b[key]
            if lib["linking"] == "dynamic" and not any(f.endswith((".so", ".dll", ".dylib")) or ".framework" in f
                                                       for f in b.get("files", [])) and not b.get("compiled_into"):
                print(f"package: {lib['name']} is LGPL but no shared library was recorded", file=sys.stderr)
                return 1
        artefacts.append(entry)
    if built is not None:
        unknown = sorted(set(built) - {lib["name"] for lib in data["libraries"]})
        if unknown:
            print(f"package: build-info for libraries missing from versions.json: {unknown}", file=sys.stderr)
            return 1
    manifest = {"target": target,
                "mediahro_deps": {"commit": git_commit(), "release": os.environ.get("GITHUB_REF_NAME")},
                "artefacts": artefacts}
    if not_built:
        manifest["not_built"] = not_built
    (staging / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    out_dir.mkdir(parents=True, exist_ok=True)
    archive = out_dir / f"mediahro-deps-{target}.tar.gz"
    reproducible_tar(staging, archive)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (out_dir / f"{archive.name}.sha256").write_text(f"{digest}  {archive.name}\n", encoding="utf-8")
    print(f"{target} {digest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
