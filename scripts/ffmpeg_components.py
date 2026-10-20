"""Check that every FFmpeg component the flags ask for is enabled in the configured build.

FFmpeg's configure warns only when a whole `--enable-decoder=a,b,c` list matches nothing, so one
misspelt name inside a list (mov_text for movtext, eia_608 for ccaption) is dropped silently. It also
disables a requested component whose dependencies are missing and only warns. This reads the configure
arguments and the generated config_components.h and fails on any requested component that is not
`#define CONFIG_<NAME>_<TYPE> 1`.

Usage: python scripts/ffmpeg_components.py BUILD_DIR/config_components.h ARG...
       (ARG: the exact configure arguments, e.g. "${FF_FLAGS[@]}"; non-component arguments are ignored)
Exit 1 lists every component that is missing.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

TYPES = {"decoder", "encoder", "demuxer", "muxer", "parser", "bsf", "protocol", "filter", "indev", "outdev", "hwaccel"}


def main() -> int:
    header, args = Path(sys.argv[1]), sys.argv[2:]
    enabled = set(re.findall(r"^#define CONFIG_(\w+) 1$", header.read_text(encoding="utf-8"), re.M))
    wanted: dict[str, str] = {}
    for a in args:
        m = re.fullmatch(r"--(enable|disable)-(\w+?)s?=(.+)", a)
        if not m or m.group(2) not in TYPES:
            continue
        for name in m.group(3).split(","):
            key = f"{name}_{m.group(2)}".upper()
            if m.group(1) == "enable":
                wanted[key] = a
            else:
                wanted.pop(key, None)
    missing = sorted(k for k in wanted if k not in enabled)
    print(f"ffmpeg_components: {len(wanted) - len(missing)}/{len(wanted)} requested components enabled")
    for k in missing:
        print(f"  not enabled: {k.lower()}  (from {wanted[k][:60]}...)", file=sys.stderr)
    if missing:
        print("ffmpeg_components: use FFmpeg's configure names (ff_<name>_<type> in allcodecs.c, allformats.c, "
              "allfilters.c ...) and check config.log for components disabled by missing dependencies", file=sys.stderr)
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
