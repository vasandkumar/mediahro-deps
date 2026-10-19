# Stage and package one Windows target (sourced by build.sh).
# Archive layout: bin/ (runtime DLLs), lib/ (import libraries, pkgconfig/),
# include/, etc/fonts/ (fontconfig configuration), licenses/, manifest.json.
# shellcheck shell=bash

# Built for linking only: the GPU driver installs vulkan-1.dll (delay-loaded);
# SPIRV-Tools' shared library is a by-product (shaderc links it statically).
STAGE_SKIP_DLLS="vulkan-1.dll SPIRV-Tools-shared.dll"

# Libraries in versions.json that this build does not produce, with the reason.
# Each one has a row in Mediahro STATUS.md §3.
NOT_BUILT_REASON_openscreen_libcast="Open Screen has no Windows platform layer (platform/impl is POSIX-only) and its TLS and Cast certificate checks need BoringSSL; see windows/README.md"

stage_target() {
  local st=$T/stage f base name
  rm -rf "$st"; mkdir -p "$st/bin" "$st/lib/pkgconfig" "$st/include" "$st/licenses" "$st/etc"
  for f in "$PREFIX"/bin/*.dll; do
    base=$(basename "$f")
    case " $STAGE_SKIP_DLLS " in *" $base "*) continue ;; esac
    cp "$f" "$st/bin/"
  done
  # Import libraries only; static archives from build-internal pieces stay out.
  "$HOST_PY" -I "$(w "$HERE/lib/stage_libs.py")" "$(w "$PREFIX/lib")" "$(w "$st/lib")" "$(w "$st/bin")" ||
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
  cp "$T"/licenses/*.txt "$st/licenses/"
  # Every library that went into the archive needs its licence text.
  while IFS= read -r name; do
    [ -f "$st/licenses/$name.txt" ] || die "$TARGET: no licence text for $name"
  done < <(sort -u "$T/built.txt")
  log "$TARGET: checking staged binaries"
  "$HOST_PY" -I "$(w "$HERE/lib/check_pe.py")" "$ARCH" "$(w "$st/bin")" > "$T/check_pe.txt" ||
    { cat "$T/check_pe.txt" >&2; die "$TARGET: PE check failed"; }
  tail -1 "$T/check_pe.txt" >&2
}

package_target() {
  local built missing=() lib reason var
  built=$(sort -u "$T/built.txt" | paste -sd, -)
  # Report what versions.json lists for windows but this build cannot produce.
  for lib in $("$HOST_PY" -I -c "import json,sys; v=json.load(open(sys.argv[1])); print(' '.join(l['name'] for l in v['libraries'] if 'windows' in l.get('platforms', ['windows'])))" "$(w "$ROOT/versions.json")"); do
    case ",$built," in *",$lib,"*) continue ;; esac
    var="NOT_BUILT_REASON_${lib//[-.]/_}"; reason=${!var:-}
    [ -n "$reason" ] || die "$TARGET: $lib is in versions.json for windows but was not built"
    missing+=("$lib")
    log "$TARGET: NOT BUILT $lib: $reason"
  done
  "$HOST_PY" -I "$(w "$HERE/lib/pins.py")" pkgroot "$(w "$T/pkgroot")" "$built"
  "$HOST_PY" -I "$(w "$T/pkgroot/scripts/package.py")" "$TARGET" "$(w "$T/stage")" "$(w "$OUT")" | tee "$T/package.txt"
}
