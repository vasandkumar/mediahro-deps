"""Resolve, download and verify the sources the Windows build uses.

Pins come from ../versions.json (lane B4a). windows/deps.json adds:
  toolchain  build-only tools (LLVM, nasm, pkgconf, gas-preprocessor, pip wheels)
  extra      transitive libraries that ship in the archive but are not in versions.json
  fallback   version + sha256 used only while a versions.json entry is still unpinned
Every download is checked against its SHA-256 before it is extracted.

Usage:
  pins.py get NAME FIELD          print version | url | sha256 | license | dir
  pins.py fetch NAME CACHE SRCDIR extract NAME into SRCDIR/<dir>, print that path
  pins.py pkgroot OUT BUILT       write a packaging root for scripts/package.py
  pins.py tofu NAME CACHE         download NAME and print its SHA-256 (pinning aid)
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import sys
import time
import urllib.request
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
WIN = HERE.parent
ROOT = WIN.parent


def _load() -> tuple[dict, dict]:
    versions = json.loads((ROOT / "versions.json").read_text(encoding="utf-8"))
    deps = json.loads((WIN / "deps.json").read_text(encoding="utf-8"))
    return versions, deps


def _expand(template: str, version: str) -> str:
    series = ".".join(version.split(".")[:2])
    return (template.replace("{version}", version).replace("{series}", series)
            .replace("{underscore}", version.replace(".", "_")))


def resolve(name: str) -> dict:
    versions, deps = _load()
    for section in ("toolchain", "extra"):
        if name in deps[section]:
            e = dict(deps[section][name])
            e["name"] = name
            e["url"] = _expand(e["source"], e["version"])
            return e
    for lib in versions["libraries"]:
        if lib["name"] != name:
            continue
        e = dict(lib)
        fb = deps["fallback"].get(name, {})
        if not e.get("version"):
            if not fb:
                raise SystemExit(f"pins: {name} is not pinned in versions.json and has no windows fallback")
            e["version"], e["sha256"] = fb["version"], fb["sha256"]
            e["source"] = fb.get("source", e["source"])
            e["pinned_by"] = "windows/deps.json fallback"
        elif fb.get("source") and fb.get("version") == e["version"]:
            e["source"] = fb["source"]
        e["url"] = _expand(e["source"], e["version"])
        return e
    raise SystemExit(f"pins: unknown source {name}")


def _archive_name(e: dict) -> str:
    base = e["url"].split("?")[0].rstrip("/").split("/")[-1]
    return f"{e['name']}-{e['version']}--{base}"


def _download(e: dict, cache: Path) -> Path:
    cache.mkdir(parents=True, exist_ok=True)
    dest = cache / _archive_name(e)
    if dest.exists() and e.get("sha256") and _sha256(dest) == e["sha256"]:
        return dest
    tmp = dest.with_suffix(dest.suffix + ".part")
    urls = [e["url"]]
    for prefix, alts in _load()[1].get("mirrors", {}).items():
        if e["url"].startswith(prefix):
            urls += [a + e["url"][len(prefix):] for a in alts]
    errors = []
    for attempt in range(6):
        for url in urls:
            try:
                req = urllib.request.Request(url, headers={"User-Agent": "mediahro-deps-build"})
                with urllib.request.urlopen(req, timeout=120) as r, open(tmp, "wb") as f:  # noqa: S310 - pinned URL, hash-checked
                    shutil.copyfileobj(r, f, 1 << 20)
                tmp.replace(dest)
                return dest
            except OSError as err:
                errors.append(f"{url}: {err}")
        time.sleep(15 * (attempt + 1))
    raise SystemExit("pins: download failed:\n  " + "\n  ".join(errors))


def _sha256(p: Path) -> str:
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _verified(e: dict, cache: Path) -> Path:
    if not e.get("sha256"):
        raise SystemExit(f"pins: {e['name']} {e['version']} has no sha256; refusing to build an unverified source")
    path = _download(e, cache)
    digest = _sha256(path)
    if digest != e["sha256"]:
        path.unlink()
        raise SystemExit(f"pins: SHA-256 mismatch for {e['name']}: got {digest}, pinned {e['sha256']}")
    return path


def _extract(archive: Path, dest: Path) -> None:
    """Extract, stripping the single top-level directory most tarballs have."""
    tmp = dest.with_name(dest.name + ".tmp")
    shutil.rmtree(tmp, ignore_errors=True)
    tmp.mkdir(parents=True)
    name = archive.name
    if name.endswith(".zip"):
        with zipfile.ZipFile(archive) as z:
            z.extractall(tmp)
    elif name.endswith((".tar.zst", ".tzst", ".tar.gz", ".tgz", ".tar.xz", ".tar.bz2", ".tar")):
        # MSYS2 tar: handles every compressor here and turns symlinks into copies.
        import subprocess

        tar = os.environ.get("MEDIAHRO_TAR", "tar")
        extra = ["--use-compress-program=zstd -d --long=31"] if name.endswith((".zst", ".tzst")) else []
        cmd = [tar, "--force-local", *extra, "-xf", archive.as_posix(), "-C", tmp.as_posix()]
        # Symlinks become copies, which fails when the target is extracted
        # later (or never exists); a second pass fills in the forward links.
        for extra_pass in ([], ["--skip-old-files"]):
            r = subprocess.run(cmd + extra_pass, capture_output=True, text=True)
            if r.returncode == 0:
                break
        bad = [ln for ln in r.stderr.splitlines() if ln.strip() and "Cannot create symlink" not in ln and "Exiting with failure status" not in ln]
        if bad:
            raise SystemExit(f"pins: extracting {archive.name} failed:\n" + "\n".join(bad))
    else:  # single file (scripts, headers)
        shutil.copy2(archive, tmp / name.split("--", 1)[1])
    entries = list(tmp.iterdir())
    src = entries[0] if len(entries) == 1 and entries[0].is_dir() else tmp
    shutil.rmtree(dest, ignore_errors=True)
    src.replace(dest) if src is not tmp else tmp.replace(dest)
    shutil.rmtree(tmp, ignore_errors=True)


def fetch(name: str, cache: Path, srcdir: Path) -> Path:
    e = resolve(name)
    dest = srcdir / f"{name}-{e['version']}"
    stamp = dest / ".mediahro-sha256"
    if stamp.exists() and stamp.read_text().strip() == e["sha256"]:
        return dest
    archive = _verified(e, cache)
    _extract(archive, dest)
    stamp.write_text(e["sha256"])
    return dest


def pkgroot(root: Path, out: Path, built: list[str]) -> None:
    """Packaging root for scripts/package.py: the repo's versions.json with the
    windows fallback pins filled in, the windows-only transitive libraries
    appended, and only the libraries this build actually produced listed, so
    manifest.json describes exactly what is in the archive."""
    versions, deps = _load()
    shutil.rmtree(out, ignore_errors=True)
    (out / "scripts").mkdir(parents=True)
    shutil.copy2(root / "scripts" / "package.py", out / "scripts" / "package.py")
    shutil.copytree(root / "flags", out / "flags")
    for f in (WIN / "flags").glob("*.flags"):
        shutil.copy2(f, out / "flags" / f"windows-extra-{f.name}")
    libs = []
    for lib in versions["libraries"]:
        if "platforms" in lib and "windows" not in lib["platforms"]:
            continue
        if lib["name"] not in built:
            continue
        e = dict(lib)
        if not e.get("version"):
            fb = deps["fallback"][lib["name"]]
            e["version"], e["sha256"] = fb["version"], fb["sha256"]
        extra_flags = WIN / "flags" / f"{lib['name']}.flags"
        if extra_flags.exists():
            e["flags"] = list(e.get("flags", [])) + [f"windows-extra-{extra_flags.name}"]
        libs.append(e)
    for name, x in deps["extra"].items():
        if name in built:
            libs.append({k: v for k, v in x.items() if k != "source"} | {"name": name, "source": _expand(x["source"], x["version"])})
    versions["libraries"] = libs
    (out / "versions.json").write_text(json.dumps(versions, indent=2), encoding="utf-8")


def main() -> int:
    cmd = sys.argv[1]
    if cmd == "get":
        e = resolve(sys.argv[2])
        field = sys.argv[3]
        print(f"{e['name']}-{e['version']}" if field == "dir" else e.get(field) or "")
    elif cmd == "fetch":
        print(fetch(sys.argv[2], Path(sys.argv[3]), Path(sys.argv[4])).as_posix())
    elif cmd == "pkgroot":
        pkgroot(ROOT, Path(sys.argv[2]), sys.argv[3].split(","))
    elif cmd == "tofu":
        e = resolve(sys.argv[2])
        e["sha256"] = None
        p = _download(e, Path(sys.argv[3]))
        print(f"{e['name']} {e['version']} {_sha256(p)} {e['url']}")
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
