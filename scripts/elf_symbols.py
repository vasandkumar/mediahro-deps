"""Fail when a shared object needs a symbol that nothing it loads defines.

Android's linker refuses to load a library with an unresolved strong symbol,
so this is checked at build time: for every .so in LIB_DIR, each undefined
dynamic symbol (weak ones excepted) must be defined by a library in its
DT_NEEDED closure, looked up in LIB_DIR and then in the NDK system stubs.

Usage: python scripts/elf_symbols.py LIB_DIR SYSTEM_STUB_DIR NM READELF
"""

from __future__ import annotations

import re
import subprocess
import sys
from functools import lru_cache
from pathlib import Path

LIB, SYS, NM, READELF = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], sys.argv[4]


def run(*args: str) -> str:
    return subprocess.run(args, capture_output=True, text=True, check=True).stdout


def locate(name: str) -> Path | None:
    for d in (LIB, SYS):
        if (d / name).exists():
            return d / name
    return None


@lru_cache(maxsize=None)
def needed(path: Path) -> tuple[str, ...]:
    return tuple(re.findall(r"\(NEEDED\).*\[(.+?)\]", run(READELF, "-dW", str(path))))


@lru_cache(maxsize=None)
def defined(path: Path) -> frozenset[str]:
    out = run(NM, "-D", "--defined-only", "--format=posix", str(path))
    return frozenset(line.split()[0].split("@")[0] for line in out.splitlines() if line.strip())


def undefined(path: Path) -> list[str]:
    out = run(NM, "-D", "--undefined-only", "--format=posix", str(path))
    syms = []
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[1] not in ("w", "v"):  # weak references may stay unresolved
            syms.append(parts[0].split("@")[0])
    return syms


def closure(path: Path) -> set[Path]:
    seen: set[Path] = set()
    stack = [path]
    while stack:
        p = stack.pop()
        for n in needed(p):
            q = locate(n)
            if q and q not in seen:
                seen.add(q)
                stack.append(q)
    return seen


def main() -> int:
    errors = 0
    for so in sorted(LIB.glob("*.so")):
        available: set[str] = set()
        for dep in closure(so):
            available |= defined(dep)
        missing = sorted(set(undefined(so)) - available - defined(so))
        if missing:
            errors += 1
            print(f"elf: {so.name} needs symbols no library it loads defines: {', '.join(missing[:8])}"
                  + (" …" if len(missing) > 8 else ""))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
