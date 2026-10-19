#!/usr/bin/env bash
# Builds every Apple-applicable library in ../versions.json as dynamic
# .frameworks, assembles one .xcframework per library and packages two targets
# with ../scripts/package.py:
#   ios-xcframeworks    iOS arm64 + iOS Simulator arm64/x86_64, iOS 16.0
#   macos-xcframeworks  macOS arm64 + x86_64 (universal), macOS 12.0
# Usage: apple/build.sh <out-dir>     (runs on macOS with Xcode 26)
#
# Development switches (environment):
#   MEDIAHRO_APPLE_SLICES  subset of: ios-arm64 iossim-arm64 iossim-x86_64 macos-arm64 macos-x86_64
#   MEDIAHRO_APPLE_ONLY    subset of recipes (see apple/recipes.sh); skips packaging
#   MEDIAHRO_APPLE_WORK    work directory (default: build/apple)

# macOS ships bash 3.2; the framework step needs bash >= 4.
if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [ -x "$b" ] && exec "$b" "$0" "$@"
  done
  HOMEBREW_NO_AUTO_UPDATE=1 brew install bash >&2 && exec "$(brew --prefix)/bin/bash" "$0" "$@"
  echo "apple/build.sh needs bash >= 4" >&2
  exit 1
fi
set -euo pipefail

[ $# -eq 1 ] || { echo "usage: apple/build.sh <out-dir>" >&2; exit 2; }
APPLE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname "$APPLE")
mkdir -p "$1"
OUT=$(cd "$1" && pwd)

# shellcheck source=lib/common.sh
. "$APPLE/lib/common.sh"
# shellcheck source=lib/frameworks.sh
. "$APPLE/lib/frameworks.sh"
# shellcheck source=recipes.sh
. "$APPLE/recipes.sh"
# Dev-only overrides for CI iterations on scratch branches (never on main).
if [ -f "$APPLE/ci-dev.env" ]; then
  # shellcheck source=/dev/null
  . "$APPLE/ci-dev.env"
fi

[ "$(uname -s)" = Darwin ] || die "Apple targets build only on macOS"
WORK=${MEDIAHRO_APPLE_WORK:-$ROOT/build/apple}
SLICES=${MEDIAHRO_APPLE_SLICES:-$ALL_SLICES}
ONLY=${MEDIAHRO_APPLE_ONLY:-}
CACHE="$WORK/cache"
LOGS="$WORK/logs"
LICENSES="$WORK/licenses"
JOBS=$(sysctl -n hw.ncpu)
mkdir -p "$CACHE" "$LOGS" "$LICENSES"
STAMP="$WORK/.stamp"
touch "$STAMP"
: >"$WORK/notes.txt"

# --- tools --------------------------------------------------------------------
log "tools"
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ENV_HINTS=1
for t in nasm pkgconf ninja cmake; do
  command -v "$t" >/dev/null 2>&1 || brew install "$t" >&2
done
NASM=$(command -v nasm)
PKGCONF=$(command -v pkgconf)
# Build-time Python tools (never shipped): meson, and jinja2 for libplacebo's code generator.
if [ ! -x "$WORK/venv/bin/meson" ]; then
  python3 -m venv "$WORK/venv"
  "$WORK/venv/bin/pip" install --quiet --disable-pip-version-check "meson==1.9.1" "jinja2==3.1.6" "markupsafe==3.0.3"
fi
export PATH="$WORK/venv/bin:$PATH"
{
  sw_vers
  xcodebuild -version
  echo "cpus: $JOBS  arch: $(uname -m)"
  cmake --version | head -1
  echo "meson $(meson --version)  ninja $(ninja --version)  nasm: $(nasm -v)  pkgconf $(pkgconf --version)"
  df -h "$WORK" | tail -1
} >&2

PINS_TSV="$WORK/pins.tsv"
python3 "$APPLE/lib/pins.py" tsv "$PINS_TSV"

# --- build each slice ----------------------------------------------------------
declare -A STEM_LIB=()
TIMES="$WORK/times.txt"
: >"$TIMES"

for slice in $SLICES; do
  slice_env "$slice"
  log "slice $SLICE ($TRIPLE)"
  rm -rf "$PREFIX" "$BUILD" "$SLICE_DIR/src"
  slice_env "$slice"
  for r in $RECIPES; do
    if [ -n "$ONLY" ] && ! printf ' %s ' $ONLY | grep -q " $r "; then continue; fi
    before=$(ls "$PREFIX"/lib/*.dylib 2>/dev/null || true)
    log "$r ($SLICE)"
    t0=$SECONDS
    "build_$r"
    echo "$SLICE $r $((SECONDS - t0))s" >>"$TIMES"
    for f in "$PREFIX"/lib/*.dylib; do
      [ -e "$f" ] && [ ! -L "$f" ] || continue
      printf '%s\n' "$before" | grep -qxF "$f" && continue
      stem=$(dylib_stem "$f")
      # glib's gettext stub is its own pinned library (LGPL, dynamic).
      if [ "$stem" = libintl ]; then STEM_LIB[$stem]=proxy-libintl; else STEM_LIB[$stem]=$r; fi
      STEM_VERSIONS+="$stem $(plist_version "$(pin_version "$r" 2>/dev/null || echo 1.0.0)")"$'\n'
    done
    # Keep the disk footprint small; libplacebo reuses the Vulkan-Headers tree.
    rm -rf "$BUILD"/*
    find "$SLICE_DIR/src" -mindepth 1 -maxdepth 1 ! -name vulkan-headers -exec rm -rf {} +
  done
  make_slice_frameworks
done
cat "$TIMES" >&2
cat "$WORK/notes.txt" >&2

if [ -n "$ONLY" ]; then
  log "MEDIAHRO_APPLE_ONLY set: built $ONLY for $SLICES; not packaging"
  exit 0
fi

# --- assemble xcframeworks and package ----------------------------------------
has_slices() { local s; for s in "$@"; do printf ' %s ' $SLICES | grep -q " $s " || return 1; done; }

stage_target() { # TARGET OS HEADER_SLICE GROUP...
  local target=$1 os=$2 hslice=$3 st="$WORK/stage/$target" pkgroot="$WORK/pkgroot" stem
  shift 3
  log "assemble $target"
  rm -rf "$st"
  mkdir -p "$st/include" "$st/licenses"
  make_xcframeworks "$st/lib" "$@"
  cp -R "$WORK/$hslice/prefix/include/." "$st/include/"
  cp "$LICENSES"/*.txt "$st/licenses/"
  {
    echo "{"
    echo "  \"comment\": \"framework stem -> versions.json / apple/pins.json library\","
    local first=1
    for stem in $(printf '%s\n' "${!STEM_LIB[@]}" | sort); do
      [ -d "$st/lib/$stem.xcframework" ] || continue
      [ $first = 1 ] || echo ","
      printf '  "%s": "%s"' "$stem" "${STEM_LIB[$stem]}"
      first=0
    done
    echo
    echo "}"
  } >"$st/frameworks.json"
  rm -rf "$pkgroot"
  mkdir -p "$pkgroot/scripts" "$pkgroot/flags"
  cp "$ROOT/scripts/package.py" "$pkgroot/scripts/"
  cp "$ROOT"/flags/*.flags "$APPLE"/flags/*.flags "$pkgroot/flags/"
  python3 "$APPLE/lib/pins.py" versions "$pkgroot/versions.json" "$os"
  python3 "$pkgroot/scripts/package.py" "$target" "$st" "$OUT"
}

packaged=0
if has_slices ios-arm64 iossim-arm64 iossim-x86_64; then
  merge_slices "$WORK/merged/ios" ios-arm64
  merge_slices "$WORK/merged/iossim" iossim-arm64 iossim-x86_64
  stage_target ios-xcframeworks ios ios-arm64 "$WORK/merged/ios" "$WORK/merged/iossim"
  packaged=$((packaged + 1))
fi
if has_slices macos-arm64 macos-x86_64; then
  merge_slices "$WORK/merged/macos" macos-arm64 macos-x86_64
  stage_target macos-xcframeworks macos macos-arm64 "$WORK/merged/macos"
  packaged=$((packaged + 1))
fi
[ "$packaged" -gt 0 ] || die "no complete target among slices: $SLICES"

log "archives"
for f in "$OUT"/*.sha256; do cat "$f"; done
ls -la "$OUT"
