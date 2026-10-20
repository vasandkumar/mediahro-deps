# Stage and package one Windows target (sourced by build.sh).
# Archive layout: bin/ (runtime DLLs), lib/ (import libraries, pkgconfig/),
# include/, etc/fonts/ (fontconfig configuration), licenses/, build-info/,
# manifest.json (scripts/package.py).
# shellcheck shell=bash

# Built for linking only: the GPU driver installs vulkan-1.dll (delay-loaded);
# SPIRV-Tools' shared library is a by-product (shaderc links it statically).
STAGE_SKIP_DLLS="vulkan-1.dll SPIRV-Tools-shared.dll"

# What Mediahro opens itself (ADR-020: nothing else ships unless one of these
# imports it): the FFI libraries (mediahro_ffi native_library.dart), libmpv and
# the FFmpeg libraries the engine remuxes with (B1), libssh2 (B2's bindings),
# and ggml's CPU backend (on x64 the variants ggml.dll picks at run time). lib/ship.py adds what
# they import or delay-load.
SHIP_ROOTS="mpv-*.dll vips-*.dll jxl.dll jxl_threads.dll avif.dll raw.dll smb2.dll libnfs.dll libcurl.dll
archive.dll ebur128.dll chromaprint.dll openmpt.dll whisper.dll uchardet.dll libssh2.dll
avformat-*.dll avcodec-*.dll avutil-*.dll ggml-cpu*.dll"

stage_target() {
  local st=$T/stage f base name
  rm -rf "$st"; mkdir -p "$st/bin" "$st/lib/pkgconfig" "$st/include" "$st/licenses" "$st/etc" "$st/build-info"
  for f in "$PREFIX"/bin/*.dll; do
    base=$(basename "$f")
    case " $STAGE_SKIP_DLLS " in *" $base "*) continue ;; esac
    cp "$f" "$st/bin/"
  done
  # shellcheck disable=SC2086
  "$HOST_PY" -I "$(w "$HERE/lib/ship.py")" prune "$(w "$st/bin")" "$(w "$T/unshipped.txt")" $SHIP_ROOTS ||
    die "$TARGET: a library the app opens was not built"
  # Import libraries only, and each must name a DLL that is staged.
  "$HOST_PY" -I "$(w "$HERE/lib/stage_libs.py")" "$(w "$PREFIX/lib")" "$(w "$st/lib")" "$(w "$st/bin")" "$(w "$T/unshipped.txt")" ||
    die "$TARGET: an import library names a DLL that is not staged"
  cp -r "$PREFIX/include/." "$st/include/"
  # conf.d entries are symlinks into share/fontconfig/conf.avail: write the
  # file contents (cp -L trips over some MSYS native symlinks).
  if [ -d "$PREFIX/etc/fonts" ]; then
    (cd "$PREFIX/etc" && find fonts -type d) | while IFS= read -r d; do mkdir -p "$st/etc/$d"; done
    (cd "$PREFIX/etc" && find fonts ! -type d) | while IFS= read -r f; do cat "$PREFIX/etc/$f" > "$st/etc/$f"; done
  fi
  # Relocatable pkg-config files: prefix relative to the .pc location.
  for f in "$PREFIX"/lib/pkgconfig/*.pc "$PREFIX"/share/pkgconfig/*.pc; do
    [ -f "$f" ] || continue
    sed -e "s#^prefix=.*#prefix=\${pcfiledir}/../..#" -e "s#$(w "$PREFIX")#\${prefix}#g" "$f" > "$st/lib/pkgconfig/$(basename "$f")"
  done
  cp "$T"/build-info/*.json "$st/build-info/"
  "$HOST_PY" -I "$(w "$HERE/lib/ship.py")" info "$(w "$st")"
  cp "$T"/licenses/*.txt "$st/licenses/"
  # Every library in the archive needs its licence text.
  for f in "$st"/build-info/*.json; do
    name=$(basename "$f" .json)
    [ -f "$st/licenses/$name.txt" ] || die "$TARGET: no licence text for $name"
  done
  log "$TARGET: checking staged binaries"
  "$HOST_PY" -I "$(w "$HERE/lib/check_pe.py")" "$ARCH" "$(w "$st/bin")" > "$T/check_pe.txt" ||
    { cat "$T/check_pe.txt" >&2; die "$TARGET: PE check failed"; }
  tail -1 "$T/check_pe.txt" >&2
  # Per-DLL sizes for the ADR-020 measurement (windows/README.md).
  (cd "$st/bin" && stat -c '%s %n' -- *.dll | sort -rn) > "$T/sizes.txt"
  sed "s/^/size: /" "$T/sizes.txt" >&2
  log "$TARGET: bin/ $(awk '{s += $1} END {printf "%.1f MiB in %d DLLs", s / 1048576, NR}' "$T/sizes.txt")"
}

package_target() {
  "$HOST_PY" -I "$(w "$ROOT/scripts/package.py")" "$TARGET" "$(w "$T/stage")" "$(w "$OUT")" | tee "$T/package.txt"
  "$HOST_PY" -I - "$(w "$T/stage/manifest.json")" <<'PY' >&2
import json, sys
m = json.load(open(sys.argv[1]))
print(f"manifest: {len(m['artefacts'])} libraries")
for n in m.get("not_built", []):
    print(f"manifest: not built: {n['name']}: {n['reason']}")
PY
}
