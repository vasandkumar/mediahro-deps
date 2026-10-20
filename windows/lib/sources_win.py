"""Run the shared scripts/sources.py (lane B4a) from native Windows Python.

sources.py calls `gpg` and `patch`. On Windows those are MSYS2 programs, which
take POSIX paths: given GNUPGHOME=C:\\...\\gnupg-x they treat it as relative
and every signature check fails. This launcher converts Windows paths in the
arguments and in GNUPGHOME with cygpath and runs MSYS2's gpg/patch, then runs
sources.py unchanged.

Usage: python windows/lib/sources_win.py MSYS2_USR_BIN <sources.py arguments...>
"""

from __future__ import annotations

import os
import re
import runpy
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
USR_BIN = Path(sys.argv[1])
WINPATH = re.compile(r"^[A-Za-z]:[\\/]")
_run = subprocess.run


def posix(p: str) -> str:
    return _run([str(USR_BIN / "cygpath.exe"), "-u", p], capture_output=True, text=True, check=True).stdout.strip()


def run(cmd, *args, **kwargs):  # noqa: ANN001, ANN002, ANN003 - same signature as subprocess.run
    if isinstance(cmd, (list, tuple)) and cmd and cmd[0] in ("gpg", "patch"):
        cmd = [str(USR_BIN / f"{cmd[0]}.exe")] + [posix(a) if isinstance(a, str) and WINPATH.match(a) else a
                                                  for a in cmd[1:]]
        env = kwargs.get("env")
        if env and env.get("GNUPGHOME") and WINPATH.match(env["GNUPGHOME"]):
            kwargs["env"] = dict(env, GNUPGHOME=posix(env["GNUPGHOME"]))
    return _run(cmd, *args, **kwargs)


subprocess.run = run
os.environ.setdefault("PYTHONUTF8", "1")
sys.argv = [str(ROOT / "scripts" / "sources.py")] + sys.argv[2:]
runpy.run_path(sys.argv[0], run_name="__main__")
