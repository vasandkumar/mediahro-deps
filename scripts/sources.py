"""Fetch, verify and unpack the upstream sources pinned in versions.json.

  python scripts/sources.py fetch --dest src [--platform android] [--only NAME ...]
      Downloads every source for the platform, checks its SHA-256 against
      versions.json and its OpenPGP signature against keys/<key>.asc, and
      only then extracts it to <dest>/<name>/. Unpinned sources fail.

  python scripts/sources.py pin [--only NAME ...] [--fetch-keys]
      Fills in missing 'sha256' fields. The digest is computed from the
      download and must agree with every upstream statement available: the
      GitHub release-asset digest, the upstream checksum file and the
      upstream signature. 'verified' records which of these were checked.
      --fetch-keys downloads an unknown signing key by the signature's issuer
      fingerprint into keys/ for review (commit it only after checking it).

  python scripts/sources.py list [--platform android]
      Prints name, version and source URL.

Sources with "verify": "git" (gitiles archives are not byte-stable) are
cloned and checked out at the pinned commit instead of hashed.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VERSIONS = ROOT / "versions.json"
KEYS = ROOT / "keys"
UA = {"User-Agent": "mediahro-deps/1 (+https://github.com/vasandkumar/mediahro-deps)"}


def load() -> dict:
    return json.loads(VERSIONS.read_text(encoding="utf-8"))


def dump(data: dict) -> None:
    """Keep versions.json reviewable: one library per line."""
    lines = ["{"]
    keys = list(data)
    for i, k in enumerate(keys):
        comma = "," if i < len(keys) - 1 else ""
        if k == "libraries":
            lines.append('  "libraries": [')
            libs = data[k]
            for j, lib in enumerate(libs):
                lines.append("    " + json.dumps(lib, ensure_ascii=False) + ("," if j < len(libs) - 1 else ""))
            lines.append("  ]" + comma)
        elif k == "toolchains":
            lines.append('  "toolchains": {')
            items = list(data[k].items())
            for j, (tk, tv) in enumerate(items):
                lines.append(f"    {json.dumps(tk)}: {json.dumps(tv)}" + ("," if j < len(items) - 1 else ""))
            lines.append("  }" + comma)
        else:
            lines.append(f"  {json.dumps(k)}: {json.dumps(data[k], ensure_ascii=False)}{comma}")
    lines.append("}")
    VERSIONS.write_text("\n".join(lines) + "\n", encoding="utf-8")


def expand(template: str, lib: dict) -> str:
    out = template
    for key in ("version", "tag", "series", "commit"):
        if lib.get(key):
            out = out.replace("{" + key + "}", str(lib[key]))
    if "{" in out:
        raise SystemExit(f"sources: {lib['name']}: unresolved placeholder in {out}")
    return out


def applies(lib: dict, platform: str | None) -> bool:
    return platform is None or "platforms" not in lib or platform in lib["platforms"]


def http_get(url: str, dest: Path, attempts: int = 4) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_suffix(dest.suffix + ".part")
    for n in range(1, attempts + 1):
        try:
            req = urllib.request.Request(url, headers=UA)
            with urllib.request.urlopen(req, timeout=120) as r, open(tmp, "wb") as f:  # noqa: S310 - reviewed URLs
                shutil.copyfileobj(r, f, 1 << 20)
            tmp.replace(dest)
            return
        except Exception as e:  # noqa: BLE001 - retried, then reported
            if n == attempts:
                raise SystemExit(f"sources: download failed: {url}: {e}") from e
            time.sleep(3 * n)


def http_text(url: str) -> str:
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=60) as r:  # noqa: S310 - reviewed URLs
        return r.read().decode("utf-8", errors="replace")


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def filename(url: str, lib: dict) -> str:
    base = url.rsplit("/", 1)[-1]
    # GitHub tag archives are named after the tag only; prefix the library.
    if "/archive/" in url:
        base = f"{lib['name']}-{base}"
    return base


# --- upstream statements -------------------------------------------------------

GH_ASSET = re.compile(r"^https://github\.com/([^/]+)/([^/]+)/releases/download/([^/]+)/([^/]+)$")


def github_asset_digest(url: str) -> str | None:
    m = GH_ASSET.match(url)
    if not m:
        return None
    owner, repo, tag, name = m.groups()
    api = f"https://api.github.com/repos/{owner}/{repo}/releases/tags/{tag}"
    headers = dict(UA)
    if os.environ.get("GITHUB_TOKEN"):
        headers["Authorization"] = f"Bearer {os.environ['GITHUB_TOKEN']}"
    req = urllib.request.Request(api, headers=headers)
    with urllib.request.urlopen(req, timeout=60) as r:  # noqa: S310
        rel = json.load(r)
    for a in rel.get("assets", []):
        if a["name"] == name and (a.get("digest") or "").startswith("sha256:"):
            return a["digest"].split(":", 1)[1]
    return None


def checksum_file_digest(url: str, fname: str) -> tuple[str, str] | None:
    """Returns (algorithm, hex) for fname from an upstream checksum file."""
    text = http_text(url)
    for line in text.splitlines():
        parts = line.replace("*", " ").split()
        if not parts:
            continue
        hexes = [p for p in parts if re.fullmatch(r"[0-9a-fA-F]{64}|[0-9a-fA-F]{128}", p)]
        if not hexes:
            continue
        names = [p for p in parts if p not in hexes]
        if names and not any(n.endswith(fname) or n.lstrip("./") == fname for n in names):
            continue
        h = hexes[0].lower()
        return ("sha512" if len(h) == 128 else "sha256", h)
    return None


def gpg_verify(sig: Path, data: Path, key: str, fingerprint: str | None) -> str:
    """Verifies sig over data with keys/<key>.asc; returns the primary key fingerprint."""
    keyfile = KEYS / f"{key}.asc"
    if not keyfile.exists():
        raise SystemExit(f"sources: missing signing key {keyfile.relative_to(ROOT)} (run pin --fetch-keys and review it)")
    home = Path(tempfile.mkdtemp(prefix="gnupg-"))
    try:
        env = dict(os.environ, GNUPGHOME=str(home))
        imp = subprocess.run(["gpg", "--batch", "--quiet", "--import", str(keyfile)], env=env,
                             capture_output=True, text=True)
        if imp.returncode != 0:
            raise SystemExit(f"sources: cannot import {keyfile.name}: {imp.stderr.strip()}")
        res = subprocess.run(["gpg", "--batch", "--status-fd", "1", "--verify", str(sig), str(data)], env=env,
                             capture_output=True, text=True, encoding="utf-8", errors="replace")
        valid = re.findall(r"^\[GNUPG:\] VALIDSIG (\S+) .* (\S+)$", res.stdout, re.M)
        if res.returncode != 0 or not valid:
            raise SystemExit(f"sources: BAD signature {sig.name}\n{res.stdout}\n{res.stderr}")
        primary = valid[0][1].upper()
        if fingerprint and primary != fingerprint.upper():
            raise SystemExit(f"sources: {sig.name} signed by {primary}, expected {fingerprint}")
        return primary
    finally:
        shutil.rmtree(home, ignore_errors=True)


def issuer_fingerprint(sig: Path) -> str | None:
    res = subprocess.run(["gpg", "--batch", "--list-packets", str(sig)], capture_output=True, text=True,
                         encoding="utf-8", errors="replace")
    m = re.search(r"issuer fpr v\d ([0-9A-F]{40,64})", res.stdout) or re.search(r"keyid ([0-9A-F]{16})", res.stdout)
    return m.group(1) if m else None


def fetch_key(fpr: str, key: str) -> None:
    # keyserver.ubuntu.com keeps user IDs; keys.openpgp.org strips unverified ones.
    for url in (f"https://keyserver.ubuntu.com/pks/lookup?op=get&options=mr&search=0x{fpr}",
                f"https://keys.openpgp.org/vks/v1/by-fingerprint/{fpr}"):
        try:
            text = http_text(url)
        except Exception:  # noqa: BLE001 - try the next keyserver
            continue
        if "BEGIN PGP PUBLIC KEY BLOCK" in text:
            KEYS.mkdir(exist_ok=True)
            (KEYS / f"{key}.asc").write_text(text, encoding="utf-8")
            out = subprocess.run(["gpg", "--batch", "--show-keys", "--with-fingerprint", str(KEYS / f"{key}.asc")],
                                 capture_output=True, text=True, encoding="utf-8", errors="replace").stdout
            print(f"  fetched key {key} ({fpr}) from {url.split('/')[2]}:\n" + "\n".join("    " + line for line in out.splitlines()))
            return
    raise SystemExit(f"sources: could not fetch key {fpr}")


# --- commands ------------------------------------------------------------------

def download(lib: dict, cache: Path) -> Path:
    url = expand(lib["source"], lib)
    path = cache / filename(url, lib)
    if not path.exists() or (lib.get("sha256") and sha256(path) != lib["sha256"]):
        http_get(url, path)
    return path


def verify_signature(lib: dict, path: Path, cache: Path, fetch_keys: bool = False) -> str | None:
    sig = lib.get("signature")
    if not sig:
        return None
    sig_url = expand(sig["url"], lib)
    sig_path = cache / (path.name + "." + sig_url.rsplit(".", 1)[-1])
    http_get(sig_url, sig_path)
    if fetch_keys and not (KEYS / f"{sig['key']}.asc").exists():
        fpr = issuer_fingerprint(sig_path)
        if not fpr:
            raise SystemExit(f"sources: no issuer in {sig_path.name}")
        fetch_key(fpr, sig["key"])
    return gpg_verify(sig_path, path, sig["key"], sig.get("fingerprint"))


def cmd_pin(args: argparse.Namespace) -> int:
    data = load()
    cache = Path(args.cache)
    failures = 0
    for lib in data["libraries"]:
        if args.only and lib["name"] not in args.only:
            continue
        if lib.get("verify") == "git" or (lib.get("sha256") and not args.force):
            continue
        try:
            path = download(lib, cache)
            digest = sha256(path)
            verified = []
            asset = github_asset_digest(expand(lib["source"], lib))
            if asset:
                if asset != digest:
                    raise SystemExit(f"GitHub asset digest {asset} != download {digest}")
                verified.append("github-release-digest")
            if lib.get("checksum"):
                found = checksum_file_digest(expand(lib["checksum"], lib), path.name)
                if not found:
                    raise SystemExit(f"{path.name} not listed in {expand(lib['checksum'], lib)}")
                algo, want = found
                got = digest if algo == "sha256" else hashlib.sha512(path.read_bytes()).hexdigest()
                if got != want:
                    raise SystemExit(f"upstream {algo} {want} != download {got}")
                verified.append(f"checksum-file-{algo}")
            fpr = verify_signature(lib, path, cache, fetch_keys=args.fetch_keys)
            if fpr:
                lib["signature"]["fingerprint"] = fpr
                verified.append("openpgp-signature")
            if not verified:
                # No upstream digest exists (GitHub tag archive or plain download):
                # the hash is computed from the HTTPS download and reviewed in the PR.
                verified.append("tag-archive" if "/archive/" in lib["source"] else "https-download")
            lib["sha256"] = digest
            lib["verified"] = verified
            print(f"pin {lib['name']} {lib['version']} {digest} {'+'.join(verified)}")
        except (SystemExit, Exception) as e:  # noqa: BLE001 - report every library, then fail
            failures += 1
            print(f"pin {lib['name']}: FAILED: {e}", file=sys.stderr)
    dump(data)
    return 1 if failures else 0


def extract(archive: Path, dest: Path) -> None:
    tmp = dest.with_name(dest.name + ".tmp")
    shutil.rmtree(tmp, ignore_errors=True)
    tmp.mkdir(parents=True)
    with tarfile.open(archive) as tf:
        kwargs = {"filter": "data"} if hasattr(tarfile, "data_filter") else {}
        tf.extractall(tmp, **kwargs)  # noqa: S202 - hash and signature verified first
    entries = list(tmp.iterdir())
    top = entries[0] if len(entries) == 1 and entries[0].is_dir() else tmp
    shutil.rmtree(dest, ignore_errors=True)
    shutil.move(str(top), str(dest))
    shutil.rmtree(tmp, ignore_errors=True)


def git_checkout(lib: dict, dest: Path) -> None:
    commit = lib["commit"]
    stamp = dest / ".mediahro-commit"
    if stamp.exists() and stamp.read_text().strip() == commit:
        return
    shutil.rmtree(dest, ignore_errors=True)
    dest.mkdir(parents=True)
    run = lambda *a: subprocess.run(["git", "-C", str(dest), *a], check=True)  # noqa: E731
    run("init", "-q")
    run("fetch", "-q", "--depth", "1", lib["git"], commit)
    run("checkout", "-q", "FETCH_HEAD")
    head = subprocess.run(["git", "-C", str(dest), "rev-parse", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
    if head != commit:
        raise SystemExit(f"sources: {lib['name']}: HEAD {head} != pinned {commit}")
    stamp.write_text(commit)


def cmd_fetch(args: argparse.Namespace) -> int:
    data = load()
    dest_root, cache = Path(args.dest), Path(args.cache)
    for lib in data["libraries"]:
        if not applies(lib, args.platform) or (args.only and lib["name"] not in args.only):
            continue
        if args.skip and lib["name"] in args.skip:
            continue
        dest = dest_root / lib["name"]
        if lib.get("verify") == "git":
            git_checkout(lib, dest)
            print(f"fetch {lib['name']} {lib['commit']} (git)")
            continue
        if not lib.get("sha256"):
            print(f"sources: {lib['name']} is not pinned", file=sys.stderr)
            return 1
        stamp = dest / ".mediahro-sha256"
        if stamp.exists() and stamp.read_text().strip() == lib["sha256"]:
            continue
        path = download(lib, cache)
        got = sha256(path)
        if got != lib["sha256"]:
            path.unlink()
            print(f"sources: SHA-256 mismatch for {lib['name']}: {got} != {lib['sha256']}", file=sys.stderr)
            return 1
        verify_signature(lib, path, cache)
        extract(path, dest)
        stamp.write_text(lib["sha256"])
        print(f"fetch {lib['name']} {lib['version']} ok")
    return 0


def cmd_list(args: argparse.Namespace) -> int:
    for lib in load()["libraries"]:
        if applies(lib, args.platform):
            print(lib["name"], lib.get("version"), expand(lib["source"], lib))
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("fetch", "pin", "list"):
        p = sub.add_parser(name)
        p.add_argument("--platform")
        p.add_argument("--only", nargs="*")
        p.add_argument("--cache", default=str(ROOT / "src" / "_downloads"))
        if name == "fetch":
            p.add_argument("--dest", default=str(ROOT / "src"))
            p.add_argument("--skip", nargs="*")
        if name == "pin":
            p.add_argument("--fetch-keys", action="store_true")
            p.add_argument("--force", action="store_true")
    args = ap.parse_args()
    return {"fetch": cmd_fetch, "pin": cmd_pin, "list": cmd_list}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
