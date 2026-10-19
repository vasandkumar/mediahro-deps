"""Licence guard for mediahro-deps (Mediahro docs/09 §2, ADR-002).

Fails if any flags file enables GPL/nonfree/version3 code, if versions.json
lists a banned library, or if an LGPL library is not dynamic.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FORBIDDEN = re.compile(
    r"--enable-(gpl|nonfree|version3)\b|-Dgpl=true|--enable-libx26[45]|--enable-librubberband"
    r"|--enable-libdvd|--enable-postproc|--enable-openssl"
)


def main() -> int:
    errors = []
    for f in sorted((ROOT / "flags").glob("*.flags")):
        for n, line in enumerate(f.read_text(encoding="utf-8").splitlines(), 1):
            if line.lstrip().startswith("#"):
                continue
            if FORBIDDEN.search(line):
                errors.append(f"{f.name}:{n}: forbidden flag {line.strip()}")
    data = json.loads((ROOT / "versions.json").read_text(encoding="utf-8"))
    banned = set(data["banned"])
    for lib in data["libraries"]:
        if lib["name"] in banned:
            errors.append(f"versions.json: {lib['name']} is banned")
        if lib["license"].startswith(("GPL", "AGPL")):
            errors.append(f"versions.json: {lib['name']} is {lib['license']}")
        if lib["license"].startswith("LGPL") and lib["linking"] != "dynamic":
            errors.append(f"versions.json: {lib['name']} is LGPL but linking={lib['linking']}")
    for e in errors:
        print(e, file=sys.stderr)
    print(f"verify_flags: {len(errors)} errors")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
