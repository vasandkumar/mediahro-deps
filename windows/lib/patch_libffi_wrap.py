"""Let glib's libffi wrap use its armasm64 path under clang-cl (Windows on Arm64).

The meson port picks win64_armasm.S (preprocessed by the C compiler, then
assembled by armasm64) only when the compiler id is 'msvc'. clang-cl has MSVC
argument syntax but id 'clang-cl', so it fell back to the GNU sysv.S, which
lacks extend_hfa_type/compress_hfa_type for the Windows ABI. x64 is unchanged.

Usage: python patch_libffi_wrap.py LIBFFI_SUBPROJECT_DIR
"""

import sys
from pathlib import Path

MARK = "# mediahro-deps: clang-cl"


def edit(path: Path, old: str, new: str) -> None:
    s = path.read_text(encoding="utf-8")
    if MARK in s:
        return
    if old not in s:
        sys.exit(f"patch_libffi_wrap: pattern not found in {path}")
    path.write_text(s.replace(old, new, 1), encoding="utf-8", newline="\n")


def main() -> int:
    d = Path(sys.argv[1])
    edit(d / "meson.build",
         "  target = 'ARM_WIN64'\n  targetdir = 'aarch64'\n  if is_msvc\n",
         "  target = 'ARM_WIN64'\n  targetdir = 'aarch64'\n  if is_msvc_like  " + MARK + " uses the armasm64 path too\n")
    edit(d / "src" / "meson.build",
         "if is_msvc\n",
         "if is_msvc or (is_msvc_like and host_cpu_family == 'aarch64')  " + MARK + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
