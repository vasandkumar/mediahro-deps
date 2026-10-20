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
#   MEDIAHRO_APPLE_MEASURE ADR-020 size table: clean ios-arm64 builds with each
#                          optimisation switched off in turn (writes
#                          <out-dir>/apple-size-table.md; no packaging)

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
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd)
SLICES=${MEDIAHRO_APPLE_SLICES:-$ALL_SLICES}
ONLY=${MEDIAHRO_APPLE_ONLY:-}
CACHE=${MEDIAHRO_APPLE_CACHE:-$WORK/cache}
LOGS="$WORK/logs"
LICENSES="$WORK/licenses"
SOURCES="$WORK/sources"
JOBS=$(sysctl -n hw.ncpu)
export LC_ALL=C SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1767225600}"
mkdir -p "$CACHE" "$LOGS" "$LICENSES"
STAMP="$WORK/.stamp"
touch "$STAMP"
: >"$WORK/notes.txt"

# --- ADR-020 measurement: one clean ios-arm64 build per switched-off optimisation
if [ -n "${MEDIAHRO_APPLE_MEASURE:-}" ] && [ -z "${MEDIAHRO_APPLE_VARIANT:-}" ]; then
  table="$OUT/apple-size-table.md"
  {
    echo "| Variant (ios-arm64, shipped frameworks) | Stripped total | Unstripped total |"
    echo "|---|---:|---:|"
  } >"$table"
  for v in all thin-lto no-icf no-gc all-o2; do
    log "measure: variant $v"
    env_args=(MEDIAHRO_APPLE_VARIANT="$v" MEDIAHRO_APPLE_SLICES=ios-arm64 MEDIAHRO_APPLE_WORK="$WORK/measure-$v"
      MEDIAHRO_APPLE_CACHE="$CACHE")
    case $v in
      thin-lto) env_args+=(MEDIAHRO_LTO=1) ;;
      no-icf) env_args+=(MEDIAHRO_NO_ICF=1) ;;
      no-gc) env_args+=(MEDIAHRO_NO_GC=1) ;;
      all-o2) env_args+=(MEDIAHRO_ALL_O2=1) ;;
    esac
    env "${env_args[@]}" "$0" "$OUT/measure-$v"
    read -r _ un st < "$WORK/measure-$v/ios-arm64/size-total.txt"
    printf '| %s | %.2f MB | %.2f MB |\n' "$v" "$(echo "${st#stripped=} / 1048576" | bc -l)" \
      "$(echo "${un#unstripped=} / 1048576" | bc -l)" >>"$table"
    cp "$WORK/measure-$v/ios-arm64/sizes.txt" "$OUT/apple-sizes-$v.txt"
    rm -rf "$WORK/measure-$v" "$OUT/measure-$v"
  done
  cat "$table" >&2
  exit 0
fi

# --- tools --------------------------------------------------------------------
log "tools"
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ENV_HINTS=1
for t in nasm pkgconf ninja cmake gpg; do
  if ! command -v "$t" >/dev/null 2>&1; then
    if [ "$t" = gpg ]; then brew install gnupg >&2; else brew install "$t" >&2; fi
  fi
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

# --- sources: pinned, hash- and signature-checked by scripts/sources.py ----------
python3 "$ROOT/scripts/verify_flags.py"
# zlib, bzip2, libxml2 and libiconv come from the Apple SDK (versions.json limits them to other platforms).
# shellcheck disable=SC2086
python3 "$ROOT/scripts/sources.py" fetch --platform apple --dest "$SOURCES" --cache "$CACHE/downloads" >&2
VERSIONS_TSV="$WORK/versions.tsv"
python3 - "$ROOT/versions.json" "$VERSIONS_TSV" <<'PY'
import json, sys
libs = json.load(open(sys.argv[1], encoding="utf-8"))["libraries"]
with open(sys.argv[2], "w") as f:
    for lib in libs:
        applies = int("platforms" not in lib or "apple" in lib["platforms"])
        f.write(f"{lib['name']}\t{lib.get('version') or ''}\t{lib.get('commit') or ''}\t{applies}\n")
PY
# Every Apple library in versions.json is built by a recipe or compiled into one
# (never narrow scope silently); recipes for libraries versions.json no longer
# lists for Apple are skipped.
APPLE_LIBS=$(awk -F'\t' '$4 == 1 { print $1 }' "$VERSIONS_TSV")
for lib in $APPLE_LIBS; do
  in_list "$lib" $RECIPES $COMPILED_IN || die "versions.json lists $lib for Apple but apple/recipes.sh has no recipe for it"
done

# --- build each slice ----------------------------------------------------------
declare -A STEM_LIB=()
TIMES="$WORK/times.txt"
: >"$TIMES"

for slice in $SLICES; do
  slice_env "$slice"
  log "slice $SLICE ($TRIPLE)"
  rm -rf "$PREFIX" "$BUILD" "$SLICE_DIR/src" "$SLICE_DIR/build-info" "$SLICE_DIR/scan"
  slice_env "$slice"
  for r in $RECIPES; do
    if [ -n "$ONLY" ] && ! in_list "$r" $ONLY; then continue; fi
    if ! in_list "$r" $APPLE_LIBS; then
      echo "skipped $r: not listed for Apple in versions.json" >>"$WORK/notes.txt"
      continue
    fi
    BEFORE_DYLIBS=$(ls "$PREFIX"/lib/*.dylib 2>/dev/null || true)
    CLAIMED=""
    STEP_ARGS=()
    set_opt_flags "$r"
    record_args "CFLAGS: $HARDEN_CFLAGS" "LDFLAGS: $HARDEN_LDFLAGS"
    log "$r ($SLICE, $OPT_LEVEL)"
    t0=$SECONDS
    "build_$r"
    echo "$SLICE $r $((SECONDS - t0))s" >>"$TIMES"
    if compgen -G "$PREFIX/lib/*.framework" >/dev/null; then
      die "$r installed a .framework into $PREFIX/lib; build it as a plain dylib (frameworks are assembled later)"
    fi
    NEW_DYLIBS=""
    for f in $(new_dylibs '*.dylib'); do
      check_dylib "$PREFIX/lib/$f"
      stem=$(fw_name "$f")
      # glib's gettext stub is its own pinned library (LGPL, dynamic).
      if [ "$stem" = intl ]; then STEM_LIB[$stem]=proxy-libintl; else STEM_LIB[$stem]=$r; fi
      STEM_VERSIONS+="$stem $(plist_version "$(pin_version "${STEM_LIB[$stem]}")")"$'\n'
      in_list "$f" $CLAIMED || NEW_DYLIBS+="$f "
    done
    # build-info for the library itself (sub-components wrote theirs in the recipe).
    if [ ! -f "$SLICE_DIR/build-info/$r.json" ]; then
      bdir="$BUILD/$r"
      [ -d "$bdir" ] || bdir="$SLICE_DIR/src/$r"
      finish "$r" "$bdir" "$SLICE_DIR/src/$r"
    fi
    # Keep the disk footprint small; libplacebo reuses the Vulkan-Headers tree.
    rm -rf "${BUILD:?}"/*
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
if [ -n "${MEDIAHRO_APPLE_VARIANT:-}" ]; then
  log "measurement variant ${MEDIAHRO_APPLE_VARIANT}: $(cat "$WORK"/*/size-total.txt)"
  exit 0
fi

# --- assemble xcframeworks and package ----------------------------------------
has_slices() { local s; for s in "$@"; do in_list "$s" $SLICES || return 1; done; }

stage_target() { # TARGET HEADER_SLICE "SLICES" GROUP...
  local target=$1 hslice=$2 slices=$3 stem name s st
  st="$WORK/stage/$target"
  shift 3
  log "assemble $target"
  rm -rf "$st"
  mkdir -p "$st/include" "$st/licenses" "$st/build-info"
  make_xcframeworks "$st/Frameworks" "$@"
  cp -R "$WORK/$hslice/prefix/include/." "$st/include/"
  # glib keeps its arch-specific glibconfig.h under lib/; ship it next to glib.h.
  if [ -f "$WORK/$hslice/prefix/lib/glib-2.0/include/glibconfig.h" ]; then
    cp "$WORK/$hslice/prefix/lib/glib-2.0/include/glibconfig.h" "$st/include/glib-2.0/"
  fi
  # One build-info per library for the whole target: configure line from the
  # header slice, source-scan results merged over every slice.
  local dirs=()
  for s in $slices; do dirs+=("$WORK/$s/build-info"); done
  python3 - "$st/build-info" "$WORK/$hslice/not_shipped.txt" "$WORK/$hslice/build-info" "${dirs[@]}" <<'PY'
import json, pathlib, sys
out, dropped_file, first, *dirs = (pathlib.Path(a) for a in sys.argv[1:])
dropped = set(dropped_file.read_text().split())
names = sorted(p.stem for p in first.glob("*.json"))
bad = []
for name in names:
    infos = [json.loads((d / f"{name}.json").read_text()) for d in dirs if (d / f"{name}.json").exists()]
    if len(infos) != len(dirs):
        sys.exit(f"stage: {name} has no build-info for every slice")
    merged = dict(json.loads((first / f"{name}.json").read_text()))
    files = sorted({f for i in infos for f in i.get("files", [])})
    merged["files"] = [f for f in files if f not in dropped]
    gone = [f for f in files if f in dropped]
    if gone:
        # Built (a dependency's build produces it) but nothing the app links or loads needs it (ADR-020).
        merged["not_shipped"] = gone
    merged["files_scanned"] = max(i.get("files_scanned", 0) for i in infos)
    for key in ("gpl_only_sources", "gpl_with_exception_sources"):
        merged[key] = sorted({f for i in infos for f in i.get(key, [])})
    bad += [f"{name}: {f}" for f in merged["gpl_only_sources"]]
    (out / f"{name}.json").write_text(json.dumps(merged, indent=2) + "\n")
if bad:
    sys.exit("stage: GPL-only sources compiled:\n" + "\n".join(bad))
PY
  for f in "$st"/build-info/*.json; do
    name=$(basename "$f" .json)
    [ -s "$LICENSES/$name.txt" ] || die "no licence text recorded for $name"
    cp "$LICENSES/$name.txt" "$st/licenses/"
  done
  {
    echo "{"
    echo "  \"comment\": \"framework stem -> versions.json library\","
    local first=1
    for stem in $(printf '%s\n' "${!STEM_LIB[@]}" | sort); do
      [ -d "$st/Frameworks/$stem.xcframework" ] || continue
      [ $first = 1 ] || echo ","
      printf '  "%s": "%s"' "$stem" "${STEM_LIB[$stem]}"
      first=0
    done
    echo
    echo "}"
  } >"$st/frameworks.json"
  python3 "$ROOT/scripts/package.py" "$target" "$st" "$OUT"
}

# total_size DIR : bytes of every framework binary under DIR (one slice or a lipo'd group)
total_size() {
  local fw stem bin t=0
  for fw in "$1"/*.framework; do
    stem=$(basename "$fw" .framework)
    if [ -d "$fw/Versions" ]; then bin="$fw/Versions/A/$stem"; else bin="$fw/$stem"; fi
    t=$((t + $(stat -f %z "$bin")))
  done
  echo "$t"
}

packaged=0
if has_slices ios-arm64 iossim-arm64 iossim-x86_64; then
  merge_slices "$WORK/merged/ios" ios-arm64
  merge_slices "$WORK/merged/iossim" iossim-arm64 iossim-x86_64
  stage_target ios-xcframeworks ios-arm64 "ios-arm64 iossim-arm64 iossim-x86_64" \
    "$WORK/merged/ios" "$WORK/merged/iossim"
  packaged=$((packaged + 1))
fi
if has_slices macos-arm64 macos-x86_64; then
  merge_slices "$WORK/merged/macos" macos-arm64 macos-x86_64
  stage_target macos-xcframeworks macos-arm64 "macos-arm64 macos-x86_64" "$WORK/merged/macos"
  packaged=$((packaged + 1))
fi
[ "$packaged" -gt 0 ] || die "no complete target among slices: $SLICES"

SIZES="$OUT/apple-sizes.md"
{
  echo "| Shipped frameworks | Total |"
  echo "|---|---:|"
  if has_slices ios-arm64; then
    printf '| iOS arm64 (what App Store thinning installs) | %.2f MB |\n' "$(echo "$(total_size "$WORK/ios-arm64/frameworks") / 1048576" | bc -l)"
  fi
  if has_slices macos-arm64 macos-x86_64; then
    printf '| macOS universal (arm64 + x86_64) | %.2f MB |\n' "$(echo "$(total_size "$WORK/merged/macos") / 1048576" | bc -l)"
    printf '| macOS arm64 slice only | %.2f MB |\n' "$(echo "$(total_size "$WORK/macos-arm64/frameworks") / 1048576" | bc -l)"
  fi
} >"$SIZES"
cat "$SIZES" >&2

log "archives"
for f in "$OUT"/*.sha256; do cat "$f"; done
ls -la "$OUT"
