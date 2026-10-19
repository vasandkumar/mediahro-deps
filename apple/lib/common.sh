# shellcheck shell=bash
# Shared helpers for apple/build.sh: slices, toolchains, pinned sources and
# the meson / CMake / autotools wrappers every recipe uses.

IOS_MIN=16.0
MACOS_MIN=12.0
ALL_SLICES="ios-arm64 iossim-arm64 iossim-x86_64 macos-arm64 macos-x86_64"
# Hardening (README "Rules"): fortify, stack protector, PIC/PIE. CFI is not
# available for Apple dylibs (see apple/README.md).
HARDEN_CFLAGS="-O2 -fPIC -D_FORTIFY_SOURCE=2 -fstack-protector-strong"
HARDEN_LDFLAGS="-Wl,-headerpad_max_install_names"

# in_list WORD LIST... : true when WORD is one of LIST (no pipe, so pipefail-safe)
in_list() { local w=$1 x; shift; for x in "$@"; do [ "$x" = "$w" ] && return 0; done; return 1; }
log() { printf '\n==> [%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die() { printf 'apple/build.sh: error: %s\n' "$*" >&2; exit 1; }

# --- pins -------------------------------------------------------------------

pin_field() { # name column(1=name 2=version 3=sha256 4=url 5=license)
  awk -F'\t' -v n="$1" -v c="$2" '$1 == n { print $c; found = 1 } END { if (!found) exit 1 }' "$PINS_TSV" \
    || die "no pin for $1"
}
pin_version() { pin_field "$1" 2; }

# fetch NAME -> path of the verified archive in the download cache
fetch() {
  local name=$1 url sha file
  url=$(pin_field "$name" 4)
  sha=$(pin_field "$name" 3)
  [ -n "$url" ] && [ -n "$sha" ] || die "$name is not pinned"
  file="$CACHE/$name-$(pin_version "$name")-${url##*/}"
  if [ ! -f "$file" ]; then
    log "download $name $(pin_version "$name")"
    curl -fsSL --retry 5 --retry-delay 5 --connect-timeout 30 -o "$file.part" "$url" || die "download failed: $url"
    mv "$file.part" "$file"
  fi
  local got
  got=$(shasum -a 256 "$file" | cut -d' ' -f1)
  if [ "$got" != "$sha" ]; then
    rm -f "$file"
    die "SHA-256 mismatch for $name: expected $sha, got $got ($url)"
  fi
  printf '%s\n' "$file"
}

# src NAME -> fresh source tree for this slice (verified before extracting)
src() {
  local name=$1 archive dir
  archive=$(fetch "$name")
  dir="$SLICE_DIR/src/$name"
  rm -rf "$dir"
  mkdir -p "$dir"
  tar -xf "$archive" -C "$dir" --strip-components=1 || die "extract failed: $archive"
  printf '%s\n' "$dir"
}

# --- licences ---------------------------------------------------------------

# license NAME FILE... : records the licence text once per library.
license() {
  local name=$1 out f
  shift
  out="$LICENSES/$name.txt"
  [ -f "$out" ] && return 0
  : >"$out"
  local files=()
  for f in "$@"; do
    if [ -f "$f" ]; then
      files+=("$f")
    else
      # Upstream renamed or moved the file: take the licence files next to it.
      echo "warning: licence file missing for $name: $f; using its siblings" >&2
      while IFS= read -r f; do files+=("$f"); done < <(find "$(dirname "$f")" -maxdepth 1 -type f \
        \( -iname 'LICEN[CS]E*' -o -iname 'COPYING*' -o -iname 'COPYRIGHT*' -o -iname 'NOTICE*' \) | sort)
    fi
  done
  [ "${#files[@]}" -gt 0 ] || die "no licence text found for $name"
  for f in "${files[@]}"; do
    grep -qxF "==> ${f##*/} <==" "$out" && continue
    { printf '==> %s <==\n' "${f##*/}"; cat "$f"; printf '\n'; } >>"$out"
  done
}

# --- slices -----------------------------------------------------------------

slice_env() {
  SLICE=$1
  case $SLICE in
    ios-arm64)     ARCH=arm64;  SDK=iphoneos;        TRIPLE=arm64-apple-ios$IOS_MIN;             SUBSYSTEM=ios;           MIN=$IOS_MIN ;;
    iossim-arm64)  ARCH=arm64;  SDK=iphonesimulator; TRIPLE=arm64-apple-ios$IOS_MIN-simulator;   SUBSYSTEM=ios-simulator; MIN=$IOS_MIN ;;
    iossim-x86_64) ARCH=x86_64; SDK=iphonesimulator; TRIPLE=x86_64-apple-ios$IOS_MIN-simulator;  SUBSYSTEM=ios-simulator; MIN=$IOS_MIN ;;
    macos-arm64)   ARCH=arm64;  SDK=macosx;          TRIPLE=arm64-apple-macos$MACOS_MIN;         SUBSYSTEM=macos;         MIN=$MACOS_MIN ;;
    macos-x86_64)  ARCH=x86_64; SDK=macosx;          TRIPLE=x86_64-apple-macos$MACOS_MIN;        SUBSYSTEM=macos;         MIN=$MACOS_MIN ;;
    *) die "unknown slice $SLICE" ;;
  esac
  case $ARCH in
    arm64) CPU_FAMILY=aarch64; HOST=aarch64-apple-darwin ;;
    x86_64) CPU_FAMILY=x86_64; HOST=x86_64-apple-darwin ;;
  esac
  PLATFORM=${SLICE%%-*}           # ios | iossim | macos
  case $PLATFORM in ios | iossim) OS=ios ;; macos) OS=macos ;; esac
  # Native only when the slice is the runner itself; everything else is a cross build.
  if [ "$SLICE" = "macos-$(uname -m)" ]; then NATIVE=1; else NATIVE=0; fi
  SYSROOT=$(xcrun --sdk "$SDK" --show-sdk-path)
  CC_BIN=$(xcrun --sdk "$SDK" -f clang)
  CXX_BIN=$(xcrun --sdk "$SDK" -f clang++)
  AR_BIN=$(xcrun --sdk "$SDK" -f ar)
  RANLIB_BIN=$(xcrun --sdk "$SDK" -f ranlib)
  STRIP_BIN=$(xcrun --sdk "$SDK" -f strip)
  TFLAGS="-target $TRIPLE -isysroot $SYSROOT"
  SLICE_DIR="$WORK/$SLICE"
  PREFIX="$SLICE_DIR/prefix"
  BUILD="$SLICE_DIR/build"
  SHIM="$SLICE_DIR/shim"
  mkdir -p "$PREFIX/lib/pkgconfig" "$PREFIX/include" "$BUILD" "$SLICE_DIR/src" "$SHIM/pkgconfig"
  export PKG_CONFIG="$PKGCONF"
  export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig:$SHIM/pkgconfig"
  unset PKG_CONFIG_PATH PKG_CONFIG_SYSROOT_DIR
  write_shims
  write_meson_cross
}

# pkg-config shims for libraries the SDK already ships (no .pc files there).
write_shims() {
  local v
  v=$(awk '/#define ZLIB_VERSION /{gsub(/"/,"",$3); print $3}' "$SYSROOT/usr/include/zlib.h")
  printf 'Name: zlib\nDescription: zlib (Apple SDK)\nVersion: %s\nLibs: -lz\nCflags:\n' "$v" >"$SHIM/pkgconfig/zlib.pc"
  printf 'Name: bzip2\nDescription: bzip2 (Apple SDK)\nVersion: 1.0.8\nLibs: -lbz2\nCflags:\n' >"$SHIM/pkgconfig/bzip2.pc"
  printf 'Name: libxml-2.0\nDescription: libxml2 (Apple SDK)\nVersion: 2.9.13\nLibs: -lxml2\nCflags: -I%s/usr/include/libxml2\n' \
    "$SYSROOT" >"$SHIM/pkgconfig/libxml-2.0.pc"
}

write_meson_cross() {
  local c cxx flags largs exe_wrapper=true
  [ "$NATIVE" = 1 ] && exe_wrapper=false
  c="['$CC_BIN', '-target', '$TRIPLE', '-isysroot', '$SYSROOT']"
  cxx="['$CXX_BIN', '-target', '$TRIPLE', '-isysroot', '$SYSROOT']"
  flags="['-O2', '-fPIC', '-D_FORTIFY_SOURCE=2', '-fstack-protector-strong']"
  largs="['-Wl,-headerpad_max_install_names', '-L$PREFIX/lib']"
  cat >"$SLICE_DIR/cross.ini" <<EOF
[binaries]
c = $c
cpp = $cxx
objc = $c
objcpp = $cxx
ar = '$AR_BIN'
strip = '$STRIP_BIN'
pkg-config = '$PKGCONF'
nasm = '$NASM'

[built-in options]
c_args = $flags
cpp_args = $flags
objc_args = $flags
objcpp_args = $flags
c_link_args = $largs
cpp_link_args = $largs
objc_link_args = $largs
objcpp_link_args = $largs

[properties]
needs_exe_wrapper = $exe_wrapper
pkg_config_libdir = ['$PREFIX/lib/pkgconfig', '$PREFIX/share/pkgconfig', '$SHIM/pkgconfig']
growing_stack = false
have_c99_vsnprintf = true
have_c99_snprintf = true
have_unix98_printf = true
va_val_copy = true
have_strlcpy = true

[host_machine]
system = 'darwin'
subsystem = '$SUBSYSTEM'
kernel = 'xnu'
cpu_family = '$CPU_FAMILY'
cpu = '$ARCH'
endian = 'little'
EOF
}

# Reads a flags file (one argument per line, # comments) into the FLAGS array.
read_flags() {
  local f=$1 line
  FLAGS=()
  [ -f "$f" ] || die "flags file missing: $f"
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    case $line in '' | '#'*) continue ;; esac
    FLAGS+=("$line")
  done <"$f"
}

# --- build-system wrappers --------------------------------------------------

# run_logged NAME CMD... : full output goes to a log; the tail is printed on failure.
run_logged() {
  local name=$1 logf
  shift
  logf="$LOGS/$SLICE-$name.log"
  if ! "$@" >>"$logf" 2>&1; then
    echo "----- first errors in $logf -----" >&2
    grep -n -m 12 -B 3 -A 6 -E "error:|Error:|ERROR:|FAILED:|Undefined symbols" "$logf" >&2 || true
    echo "----- last 150 lines of $logf -----" >&2
    tail -n 150 "$logf" >&2
    for f in $(find "$BUILD" -name config.log -newer "$STAMP" 2>/dev/null) \
             $(find "$BUILD" -name meson-log.txt -newer "$STAMP" 2>/dev/null) \
             $(find "$BUILD" -name CMakeError.log -newer "$STAMP" 2>/dev/null) \
             $(find "$BUILD" -name CMakeConfigureLog.yaml -newer "$STAMP" 2>/dev/null); do
      echo "----- last 80 lines of $f -----" >&2
      tail -n 80 "$f" >&2
    done
    die "$name failed on $SLICE (command: $*)"
  fi
}

# meson_build NAME SRC [meson args...]
meson_build() {
  local name=$1 srcdir=$2 b
  shift 2
  b="$BUILD/$name"
  rm -rf "$b"
  run_logged "$name" env -u CC -u CXX -u CFLAGS -u CXXFLAGS -u LDFLAGS -u CPPFLAGS \
    meson setup "$b" "$srcdir" --cross-file "$SLICE_DIR/cross.ini" \
    --prefix "$PREFIX" --libdir lib --buildtype release -Db_ndebug=if-release \
    -Ddefault_library=shared --wrap-mode=nodownload "$@"
  run_logged "$name" meson compile -C "$b" -j "$JOBS"
  run_logged "$name" meson install -C "$b" --no-rebuild
}

# cmake_build NAME SRC [cmake args...]
cmake_build() {
  local name=$1 srcdir=$2 b sys=()
  shift 2
  b="$BUILD/$name"
  rm -rf "$b"
  if [ "$OS" = ios ]; then
    sys=(-DCMAKE_SYSTEM_NAME=iOS)
  elif [ "$NATIVE" = 0 ]; then
    sys=(-DCMAKE_SYSTEM_NAME=Darwin)
  fi
  run_logged "$name" env -u CC -u CXX -u CFLAGS -u CXXFLAGS -u LDFLAGS -u CPPFLAGS \
    cmake -S "$srcdir" -B "$b" -G Ninja "${sys[@]}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_INSTALL_NAME_DIR="$PREFIX/lib" \
    -DCMAKE_PREFIX_PATH="$PREFIX" -DCMAKE_FIND_ROOT_PATH="$PREFIX" \
    -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=BOTH \
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=BOTH -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH \
    -DCMAKE_SYSTEM_PROCESSOR="$ARCH" \
    -DCMAKE_OSX_SYSROOT="$SYSROOT" -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN" \
    -DCMAKE_C_COMPILER="$CC_BIN" -DCMAKE_CXX_COMPILER="$CXX_BIN" \
    -DCMAKE_OBJC_COMPILER="$CC_BIN" -DCMAKE_OBJCXX_COMPILER="$CXX_BIN" \
    -DCMAKE_ASM_NASM_COMPILER="$NASM" \
    -DCMAKE_C_FLAGS="-target $TRIPLE $HARDEN_CFLAGS" \
    -DCMAKE_CXX_FLAGS="-target $TRIPLE $HARDEN_CFLAGS" \
    -DCMAKE_OBJC_FLAGS="-target $TRIPLE $HARDEN_CFLAGS" \
    -DCMAKE_OBJCXX_FLAGS="-target $TRIPLE $HARDEN_CFLAGS" \
    -DCMAKE_ASM_FLAGS="-target $TRIPLE" \
    -DCMAKE_SHARED_LINKER_FLAGS="$HARDEN_LDFLAGS" \
    -DCMAKE_MODULE_LINKER_FLAGS="$HARDEN_LDFLAGS" \
    -DCMAKE_EXE_LINKER_FLAGS="$HARDEN_LDFLAGS" \
    -DCMAKE_MACOSX_BUNDLE=OFF \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DBUILD_SHARED_LIBS=ON -DBUILD_TESTING=OFF \
    "$@"
  run_logged "$name" cmake --build "$b" -j "$JOBS"
  run_logged "$name" cmake --install "$b"
}

# Environment for autotools-style configure scripts. The target triple and
# sysroot live in CC/CXX themselves: libtool drops unknown flags such as
# -target from LDFLAGS when it links a dylib.
autotools_env() {
  env CC="$CC_BIN $TFLAGS" CXX="$CXX_BIN $TFLAGS" OBJC="$CC_BIN $TFLAGS" \
    AR="$AR_BIN" RANLIB="$RANLIB_BIN" STRIP="$STRIP_BIN" \
    CFLAGS="$HARDEN_CFLAGS" CXXFLAGS="$HARDEN_CFLAGS" OBJCFLAGS="$HARDEN_CFLAGS" \
    CPPFLAGS="-I$PREFIX/include" \
    LDFLAGS="$TFLAGS -L$PREFIX/lib $HARDEN_LDFLAGS" \
    "$@"
}

host_args() {
  if [ "$NATIVE" = 1 ]; then
    HOST_ARGS=()
  else
    HOST_ARGS=(--build="$(uname -m | sed 's/arm64/aarch64/')-apple-darwin$(uname -r)" --host="$HOST")
  fi
}

# autotools_build NAME SRC [configure args...]  (builds in-tree)
autotools_build() {
  local name=$1 srcdir=$2
  shift 2
  host_args
  (cd "$srcdir" && run_logged "$name" autotools_env ./configure --prefix="$PREFIX" "${HOST_ARGS[@]}" \
    --enable-shared --disable-static "$@")
  run_logged "$name" make -C "$srcdir" -j "$JOBS"
  run_logged "$name" make -C "$srcdir" install
}

# wrap_static NAME LIB.a DYLIB VERSION [extra link args...]
# Turns a static archive into a dylib for libraries whose own build cannot
# produce Apple dylibs for every slice (the dylib becomes a framework later).
wrap_static() {
  local name=$1 archive=$2 dylib=$3 version=$4
  shift 4
  run_logged "$name" "$CXX_BIN" $TFLAGS -dynamiclib -o "$PREFIX/lib/$dylib" \
    -Wl,-force_load,"$archive" -L"$PREFIX/lib" "$@" \
    -install_name "$PREFIX/lib/$dylib" -current_version "$version" -compatibility_version "${version%%.*}" \
    -Wl,-dead_strip_dylibs $HARDEN_LDFLAGS
  rm -f "$archive"
}

# check_dylib FILE : right architecture, platform and deployment target.
check_dylib() {
  local f=$1 archs plat minos want
  archs=$(lipo -archs "$f")
  [ "$archs" = "$ARCH" ] || die "${f##*/} ($SLICE) is built for '$archs', expected $ARCH"
  read -r plat minos < <(otool -l "$f" | awk '/cmd LC_BUILD_VERSION/ { b = 1 } b && $1 == "platform" { p = $2 } b && $1 == "minos" { print p, $2; exit }') || true
  case $PLATFORM in
    macos) want="1 MACOS" ;;
    ios) want="2 IOS" ;;
    iossim) want="7 IOSSIMULATOR" ;;
  esac
  [[ " $want " == *" ${plat:-none} "* ]] || die "${f##*/} ($SLICE) has platform '${plat:-none}', expected $PLATFORM"
  [ "$(printf '%s\n%s\n' "$minos" "$MIN" | sort -V | tail -1)" = "$MIN" ] \
    || die "${f##*/} ($SLICE) requires $minos, newer than the deployment target $MIN"
}

# Fails when a configure step silently dropped a feature we asked for.
require_grep() { # FILE PATTERN WHAT
  grep -q -- "$2" "$1" || die "$3 ($SLICE): '$2' not found in ${1##*/}"
}
