#!/usr/bin/env bash
# Mediahro native dependencies for Windows (lane B4c; Mediahro docs/05 §4.1, §10).
#
#   windows/build.sh <out-dir>
#
# Builds every library in ../versions.json that applies to windows as DLLs plus
# import libraries for windows-x64 and windows-arm64 with clang-cl + MSVC
# link.exe (/guard:cf, /DYNAMICBASE, /HIGHENTROPYVA, /NXCOMPAT, /GS; /CETCOMPAT
# on x64), stages bin/ lib/ include/ licenses/ and runs scripts/package.py.
# TLS comes from Schannel, libssh2 uses WinCNG; no OpenSSL, no GPL code, no
# libheif/libde265.
#
# Runs from Git Bash or MSYS2 bash; re-executes itself under MSYS2 (make, perl).
# Environment (all optional):
#   MEDIAHRO_TARGETS   "x64 arm64" (default)
#   MEDIAHRO_WORK      work dir (default <repo>/build/windows; keep it short)
#   MEDIAHRO_ONLY      comma list of recipes to run (iteration aid)
#   MEDIAHRO_REBUILD   comma list of recipes to rebuild even if stamped
#   MEDIAHRO_JOBS      parallel jobs (default: nproc)
#   MSYS2_ROOT         MSYS2 install (default C:/msys64)
set -euo pipefail

if [ -z "${MEDIAHRO_IN_MSYS2:-}" ]; then
  msys=$(cygpath -u "${MSYS2_ROOT:-C:/msys64}")
  [ -x "$msys/usr/bin/bash.exe" ] || { echo "build.sh: MSYS2 not found at $msys (set MSYS2_ROOT)" >&2; exit 1; }
  export MEDIAHRO_IN_MSYS2=1 MSYSTEM=MSYS MSYS2_PATH_TYPE=inherit CHERE_INVOKING=1
  self=$(cd "$(dirname "$0")" && pwd -W)/$(basename "$0")
  # Hop through cmd.exe: a Cygwin-family runtime does not hand its environment
  # to a child that uses a different msys-2.0.dll (Git Bash -> MSYS2).
  exec cmd.exe //d //c "$(cygpath -w "$msys/usr/bin/bash.exe")" --login "$self" "$@"
fi

unset MSYS2_ARG_CONV_EXCL
[ -n "${MEDIAHRO_TRACE:-}" ] && set -x
[ $# -eq 1 ] || { echo "usage: windows/build.sh <out-dir>" >&2; exit 2; }
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
mkdir -p "$1"; OUT=$(cd "$1" && pwd)
WORK=${MEDIAHRO_WORK:-$ROOT/build/windows}; mkdir -p "$WORK"; WORK=$(cd "$WORK" && pwd)
CACHE=$WORK/cache SRC=$WORK/src
JOBS=${MEDIAHRO_JOBS:-$(nproc)}
TARGETS=${MEDIAHRO_TARGETS:-x64 arm64}
mkdir -p "$WORK/tmp"; TMP=$(cygpath -m "$WORK/tmp"); TEMP=$TMP; export TMP TEMP
MEDIAHRO_TAR=$(cygpath -w /usr/bin/tar.exe); export MEDIAHRO_TAR

# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
# shellcheck source=lib/recipes.sh
. "$HERE/lib/recipes.sh"

ensure_msys_packages
HOST_PY=$(find_python)
setup_tools
( T=$WORK/host; mkdir -p "$T"; load_msvc_env x64; build_host_pkgconf )

want() {  # want RECIPE: honour MEDIAHRO_ONLY
  [ -z "${MEDIAHRO_ONLY:-}" ] && return 0
  case ",$MEDIAHRO_ONLY," in *",$1,"*) return 0 ;; esac
  return 1
}

run_recipe() {
  local r=$1 stamp key logf start
  stamp=$T/stamps/$r; logf=$T/logs/$r.log
  mkdir -p "$T/stamps" "$T/logs"
  key=$( { declare -f "r_$r"; cat "$HERE/deps.json" "$ROOT/versions.json" "$T/meson.ini"; ls "$HERE/patches/$r" 2>/dev/null || true; cat "$HERE/flags/$r.flags" 2>/dev/null || true; } | sha256sum | cut -c1-16)
  case ",${MEDIAHRO_REBUILD:-}," in *",$r,"*) rm -f "$stamp" ;; esac
  if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$key" ]; then
    cat "$T/stamps/$r.built" >> "$T/built.txt" 2>/dev/null || true
    log "$TARGET $r: up to date"; return 0
  fi
  start=$SECONDS
  log "$TARGET $r"
  : > "$T/built.new"
  # Not inside `if`/`&&`: bash ignores errexit in a tested subshell.
  local rc
  set +e
  ( set -euo pipefail; B=$T/build/$r; "r_$r" ) > "$logf" 2>&1
  rc=$?
  set -e
  if [ $rc -ne 0 ]; then
    echo "---- last 150 lines of $logf ----" >&2; tail -n 150 "$logf" >&2
    die "$TARGET $r failed"
  fi
  printf '%s\n' "$key" > "$stamp"
  log "$TARGET $r: ok ($((SECONDS - start)) s)"
}

for ARCH in $TARGETS; do
  TARGET=windows-$ARCH
  T=$WORK/$TARGET PREFIX=$WORK/$TARGET/prefix
  mkdir -p "$PREFIX/bin" "$PREFIX/lib" "$PREFIX/include"
  : > "$T/built.txt"
  load_msvc_env "$ARCH"
  write_toolchains "$ARCH"
  for r in $RECIPES; do
    want "$r" || continue
    built() { local n; for n in "$@"; do echo "$n" >> "$T/built.txt"; echo "$n" >> "$T/stamps/$r.built.tmp"; done; }
    rm -f "$T/stamps/$r.built.tmp"
    run_recipe "$r"
    [ -f "$T/stamps/$r.built.tmp" ] && mv -f "$T/stamps/$r.built.tmp" "$T/stamps/$r.built"
  done
  [ -n "${MEDIAHRO_ONLY:-}" ] && continue
  stage_target
  package_target
done
