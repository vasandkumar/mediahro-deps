# shellcheck shell=bash
# Turns each slice's installed dylibs into dynamic .framework bundles, merges
# slices with lipo and assembles one .xcframework per library.
#
# Naming contract (packages/mediahro_ffi nativeLibraryFileName and lane B1's
# engine loader): every dylib lib<name>[.N...].dylib becomes
# <name>.framework/<name>, e.g. mpv.framework/mpv, vips.framework/vips,
# avcodec.framework/avcodec, MoltenVK.framework/MoltenVK. Install names are
# @rpath/<name>.framework/<name> (iOS) and
# @rpath/<name>.framework/Versions/A/<name> (macOS).
#
# Only what the app links or loads ships (ADR-020): the dependency closure of
# APP_ROOTS = mpv (and the FFmpeg libraries B1 opens for CAST-005 remux) plus
# every NativeLibrary in packages/mediahro_ffi/lib/src/native/native_library.dart.
APP_ROOTS="mpv avformat avcodec avutil avfilter swscale swresample vips jxl avif raw smb2 nfs curl archive
ebur128 chromaprint openmpt whisper uchardet tesseract leptonica"

# dylib_stem libfoo.1.2.3.dylib -> libfoo ; libglib-2.0.0.dylib -> libglib-2
dylib_stem() {
  local b=${1##*/}
  b=${b%.dylib}
  while [[ $b =~ ^(.+)\.[0-9]+$ ]]; do b=${BASH_REMATCH[1]}; done
  printf '%s\n' "$b"
}

# fw_name PATH -> framework name: libfoo.1.2.dylib -> foo ; libglib-2.0.0.dylib -> glib-2
fw_name() {
  local b
  b=$(dylib_stem "$1")
  [ "${b#lib}" != "" ] && b=${b#lib}
  printf '%s\n' "$b"
}

fw_binary_rel() { # OS STEM -> path of the binary inside the .framework
  if [ "$1" = macos ]; then printf 'Versions/A/%s\n' "$2"; else printf '%s\n' "$2"; fi
}

# Version string for Info.plist: up to three numeric components.
plist_version() {
  local v
  v=$(printf '%s' "$1" | sed -E 's/[^0-9.].*$//' | cut -d. -f1-3)
  [ -n "$v" ] || v=1.0.0
  printf '%s\n' "$v"
}

write_info_plist() { # PATH STEM VERSION OS SDK
  local path=$1 stem=$2 ver=$3 os=$4 sdk=$5 id minkey minval platform
  id="org.mediahro.deps.$(printf '%s' "$stem" | tr -c 'A-Za-z0-9.\n-' '-')"
  if [ "$os" = macos ]; then
    minkey=LSMinimumSystemVersion; minval=$MACOS_MIN; platform=MacOSX
  else
    minkey=MinimumOSVersion; minval=$IOS_MIN
    if [ "$sdk" = iphoneos ]; then platform=iPhoneOS; else platform=iPhoneSimulator; fi
  fi
  cat >"$path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key><string>en</string>
	<key>CFBundleExecutable</key><string>$stem</string>
	<key>CFBundleIdentifier</key><string>$id</string>
	<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
	<key>CFBundleName</key><string>$stem</string>
	<key>CFBundlePackageType</key><string>FMWK</string>
	<key>CFBundleShortVersionString</key><string>$ver</string>
	<key>CFBundleVersion</key><string>$ver</string>
	<key>CFBundleSupportedPlatforms</key><array><string>$platform</string></array>
	<key>$minkey</key><string>$minval</string>
</dict>
</plist>
EOF
  plutil -lint "$path" >/dev/null || die "bad Info.plist $path"
}

# The library version recorded for a framework stem (best effort from pins).
STEM_VERSIONS=""
stem_version() {
  local v
  v=$(printf '%s\n' "$STEM_VERSIONS" | awk -v s="$1" '$1 == s { print $2; exit }')
  printf '%s\n' "${v:-1.0.0}"
}

# make_slice_frameworks: $PREFIX/lib/*.dylib -> $SLICE_DIR/frameworks/*.framework
make_slice_frameworks() {
  local out="$SLICE_DIR/frameworks" f stem rel fw bin dep dstem id rp
  local -A stems=()
  rm -rf "$out"
  mkdir -p "$out"
  log "frameworks for $SLICE"
  for f in "$PREFIX"/lib/*.dylib; do
    [ -L "$f" ] && continue
    stem=$(fw_name "$f")
    [ -z "${stems[$stem]:-}" ] || die "two dylibs map to framework $stem: ${stems[$stem]} and $f"
    stems[$stem]=$f
  done
  [ "${#stems[@]}" -gt 0 ] || die "no dylibs in $PREFIX/lib"
  for stem in "${!stems[@]}"; do
    f=${stems[$stem]}
    fw="$out/$stem.framework"
    rel=$(fw_binary_rel "$OS" "$stem")
    if [ "$OS" = macos ]; then
      mkdir -p "$fw/Versions/A/Resources"
      ln -s A "$fw/Versions/Current"
      ln -s "Versions/Current/$stem" "$fw/$stem"
      ln -s Versions/Current/Resources "$fw/Resources"
      write_info_plist "$fw/Versions/A/Resources/Info.plist" "$stem" "$(stem_version "$stem")" "$OS" "$SDK"
    else
      mkdir -p "$fw"
      write_info_plist "$fw/Info.plist" "$stem" "$(stem_version "$stem")" "$OS" "$SDK"
    fi
    bin="$fw/$rel"
    cp "$f" "$bin"
    chmod u+w "$bin"
    install_name_tool -id "@rpath/$stem.framework/$rel" "$bin" 2>/dev/null
    id=$(otool -D "$f" | tail -n +2)
    while read -r dep; do
      [ -n "$dep" ] || continue
      [ "$dep" = "$id" ] && continue
      case $dep in
        /usr/lib/* | /System/Library/*) continue ;;
      esac
      dstem=$(fw_name "$dep")
      [ -n "${stems[$dstem]:-}" ] || die "$stem ($SLICE) links $dep, which is not one of our frameworks"
      install_name_tool -change "$dep" "@rpath/$dstem.framework/$(fw_binary_rel "$OS" "$dstem")" "$bin" 2>/dev/null
    done < <(otool -L "$f" | tail -n +2 | awk '{print $1}')
    while read -r rp; do
      if [ -n "$rp" ]; then install_name_tool -delete_rpath "$rp" "$bin" 2>/dev/null; fi
    done < <(otool -l "$bin" | awk '/cmd LC_RPATH/ { getline; getline; print $2 }')
    if [ "$OS" = macos ]; then
      install_name_tool -add_rpath "@loader_path/../../.." "$bin" 2>/dev/null
    else
      install_name_tool -add_rpath "@loader_path/.." "$bin" 2>/dev/null
    fi
  done
  : >"$SLICE_DIR/sizes.txt"
  : >"$SLICE_DIR/not_shipped.txt"
  # MEDIAHRO_APPLE_ONLY development builds lack the app libraries: keep everything.
  [ -n "${ONLY:-}" ] || ship_closure "$out"
  # Sizes of what ships (ADR-020 table): before and after stripping local symbols.
  local before=0 after=0 n
  for fw in "$out"/*.framework; do
    stem=$(basename "$fw" .framework)
    bin="$fw/$(fw_binary_rel "$OS" "$stem")"
    n=$(stat -f %z "$bin"); before=$((before + n))
    "$STRIP_BIN" -x "$bin"
    n=$(stat -f %z "$bin"); after=$((after + n))
    printf '%s %s\n' "$stem" "$n" >>"$SLICE_DIR/sizes.txt"
  done
  printf '%s unstripped=%s stripped=%s\n' "$SLICE" "$before" "$after" >"$SLICE_DIR/size-total.txt"
  check_slice_frameworks "$out"
}

# ship_closure DIR : keep the dependency closure of APP_ROOTS, drop the rest
# (recorded in not_shipped.txt and in each library's build-info).
ship_closure() {
  local out=$1 queue=() name dep fw
  local -A keep=()
  for name in $APP_ROOTS; do
    [ -d "$out/$name.framework" ] || die "app library $name.framework was not built ($SLICE)"
    keep[$name]=1
    queue+=("$name")
  done
  while [ "${#queue[@]}" -gt 0 ]; do
    name=${queue[0]}
    queue=("${queue[@]:1}")
    while read -r dep; do
      [[ $dep == @rpath/*.framework/* ]] || continue
      dep=${dep#@rpath/}
      dep=${dep%%.framework/*}
      if [ -z "${keep[$dep]:-}" ]; then keep[$dep]=1; queue+=("$dep"); fi
    done < <(otool -L "$out/$name.framework/$(fw_binary_rel "$OS" "$name")" | tail -n +2 | awk '{print $1}')
  done
  for fw in "$out"/*.framework; do
    name=$(basename "$fw" .framework)
    if [ -z "${keep[$name]:-}" ]; then
      echo "$name.framework" >>"$SLICE_DIR/not_shipped.txt"
      rm -rf "$fw"
    fi
  done
}

# Every load command must point at the OS or at one of our frameworks.
check_slice_frameworks() {
  local out=$1 fw stem bin bad=0 dep
  for fw in "$out"/*.framework; do
    stem=$(basename "$fw" .framework)
    bin="$fw/$(fw_binary_rel "$OS" "$stem")"
    [ -f "$bin" ] || { echo "missing binary $bin" >&2; bad=1; continue; }
    in_list "$ARCH" $(lipo -archs "$bin") || { echo "wrong arch in $stem: $(lipo -archs "$bin")" >&2; bad=1; }
    while read -r dep; do
      case $dep in
        /usr/lib/* | /System/Library/* | @rpath/*.framework/*) ;;
        *) echo "bad load command in $stem: $dep" >&2; bad=1 ;;
      esac
    done < <(otool -L "$bin" | tail -n +2 | awk '{print $1}')
    # otool's first line is the file name itself (inside $WORK): skip it.
    if otool -l "$bin" | tail -n +2 | grep -F "$WORK" >/dev/null; then
      echo "build path leaked into $stem:" >&2
      otool -l "$bin" | tail -n +2 | grep -n -B4 -F "$WORK" >&2 || true
      bad=1
    fi
  done
  [ "$bad" = 0 ] || die "framework checks failed for $SLICE"
}

sign_adhoc() { # FRAMEWORK...  (the app build re-signs with the real identity)
  local fw
  for fw in "$@"; do
    codesign --force --sign - --timestamp=none "$fw" >/dev/null 2>&1 || die "codesign failed: $fw"
  done
}

# merge_slices OUT SLICE... : lipo the same frameworks from several slices
merge_slices() {
  local out=$1 first fw stem rel s bins
  shift
  first=$1
  rm -rf "$out"
  mkdir -p "$out"
  for fw in "$WORK/$first/frameworks"/*.framework; do
    stem=$(basename "$fw" .framework)
    cp -R "$fw" "$out/"
    if [ -d "$fw/Versions" ]; then rel="Versions/A/$stem"; else rel=$stem; fi
    bins=()
    for s in "$@"; do
      [ -e "$WORK/$s/frameworks/$stem.framework/$rel" ] || die "$stem.framework missing from slice $s"
      bins+=("$WORK/$s/frameworks/$stem.framework/$rel")
    done
    if [ "${#bins[@]}" -gt 1 ]; then
      lipo -create "${bins[@]}" -output "$out/$stem.framework/$rel"
    fi
  done
  for s in "$@"; do
    local a b
    a=$(cd "$WORK/$first/frameworks" && ls)
    b=$(cd "$WORK/$s/frameworks" && ls)
    [ "$a" = "$b" ] || die "slices $first and $s produced different framework sets"
  done
  sign_adhoc "$out"/*.framework
}

# make_xcframeworks DEST GROUPDIR... : one .xcframework per framework stem
make_xcframeworks() {
  local dest=$1 g fw stem args
  shift
  rm -rf "$dest"
  mkdir -p "$dest"
  for fw in "$1"/*.framework; do
    stem=$(basename "$fw" .framework)
    args=()
    for g in "$@"; do
      args+=(-framework "$g/$stem.framework")
    done
    xcodebuild -create-xcframework "${args[@]}" -output "$dest/$stem.xcframework" >>"$LOGS/xcframework.log" 2>&1 \
      || { tail -n 40 "$LOGS/xcframework.log" >&2; die "xcodebuild -create-xcframework failed for $stem"; }
  done
}
