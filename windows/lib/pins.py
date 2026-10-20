"""Fetch and verify the Windows build tools pinned in windows/deps.json.

Library sources come from versions.json through scripts/sources.py (lane B4a);
this only covers the toolchain the Windows build adds (LLVM clang-cl, nasm,
pkgconf). Every download is checked against its SHA-256 before extraction.

Usage:
  pins.py get NAME FIELD           print version | url | sha256
  pins.py fetch NAME CACHE DEST    extract NAME into DEST/<name>-<version>, print that path
  pins.py tofu NAME CACHE          download NAME and print its SHA-256 (pinning aid)
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.request
import zipfile
from pathlib import Path

WIN = Path(__file__).resolve().parent.parent


def resolve(name: str) -> dict:
    tools = json.loads((WIN / "deps.json").read_text(encoding="utf-8"))["toolchain"]
    if name not in tools:
        raise SystemExit(f"pins: unknown tool {name}")
    e = dict(tools[name], name=name)
    e["url"] = e["source"].replace("{version}", e["version"])
    return e


def _sha256(p: Path) -> str:
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _download(e: dict, cache: Path) -> Path:
    cache.mkdir(parents=True, exist_ok=True)
    dest = cache / f"{e['name']}-{e['version']}--{e['url'].rsplit('/', 1)[-1]}"
    if dest.exists() and e.get("sha256") and _sha256(dest) == e["sha256"]:
        return dest
    tmp = dest.with_suffix(dest.suffix + ".part")
    for attempt in range(6):
        try:
            req = urllib.request.Request(e["url"], headers={"User-Agent": "mediahro-deps-build"})
            with urllib.request.urlopen(req, timeout=120) as r, open(tmp, "wb") as f:  # noqa: S310 - pinned, hash-checked
                shutil.copyfileobj(r, f, 1 << 20)
            tmp.replace(dest)
            return dest
        except OSError as err:
            if attempt == 5:
                raise SystemExit(f"pins: download failed: {e['url']}: {err}")
            time.sleep(15 * (attempt + 1))
    return dest


def _extract(archive: Path, dest: Path) -> None:
    tmp = dest.with_name(dest.name + ".tmp")
    shutil.rmtree(tmp, ignore_errors=True)
    tmp.mkdir(parents=True)
    name = archive.name
    if name.endswith(".zip"):
        with zipfile.ZipFile(archive) as z:
            z.extractall(tmp)
    else:  # .tar.* through MSYS2 tar (zstd with a long window for LLVM)
        tar = os.environ.get("MEDIAHRO_TAR", "tar")
        extra = ["--use-compress-program=zstd -d --long=31"] if name.endswith(".zst") else []
        subprocess.run([tar, "--force-local", *extra, "-xf", archive.as_posix(), "-C", tmp.as_posix()], check=True)
    entries = list(tmp.iterdir())
    src = entries[0] if len(entries) == 1 and entries[0].is_dir() else tmp
    shutil.rmtree(dest, ignore_errors=True)
    src.replace(dest)
    shutil.rmtree(tmp, ignore_errors=True)


def fetch(name: str, cache: Path, root: Path) -> Path:
    e = resolve(name)
    dest = root / f"{name}-{e['version']}"
    stamp = dest / ".mediahro-sha256"
    if stamp.exists() and stamp.read_text().strip() == e["sha256"]:
        return dest
    archive = _download(e, cache)
    digest = _sha256(archive)
    if digest != e["sha256"]:
        archive.unlink()
        raise SystemExit(f"pins: SHA-256 mismatch for {name}: got {digest}, pinned {e['sha256']}")
    _extract(archive, dest)
    stamp.write_text(e["sha256"])
    return dest


def main() -> int:
    cmd = sys.argv[1]
    if cmd == "get":
        print(resolve(sys.argv[2]).get(sys.argv[3]) or "")
    elif cmd == "fetch":
        print(fetch(sys.argv[2], Path(sys.argv[3]), Path(sys.argv[4])).as_posix())
    elif cmd == "tofu":
        e = resolve(sys.argv[2])
        e["sha256"] = None
        print(f"{e['name']} {e['version']} {_sha256(_download(e, Path(sys.argv[3])))} {e['url']}")
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
