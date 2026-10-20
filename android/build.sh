#!/usr/bin/env bash
# Build every Android native library Mediahro ships (docs/05 §4.1, §10) and
# package one archive per ABI with scripts/package.py.
#
#   android/build.sh <out-dir> [abi ...]        (default: all three ABIs)
#
# Environment:
#   ANDROID_NDK_HOME / ANDROID_NDK_ROOT   NDK r28+ (versions.json "toolchains")
#   MEDIAHRO_WORK   work tree for sources, builds, prefixes (default: build/android)
#   JOBS            parallel jobs (default: nproc)
#   ONLY            space-separated recipe names to (re)build, for development
#   SKIP            space-separated recipe names to leave out, for development
#   SOURCES_SKIP    sources not to fetch (already present in $MEDIAHRO_WORK/src), for development
#
# Policy (docs/09 §2): no GPL code, no OpenSSL/BoringSSL/mbedTLS/GnuTLS, LGPL
# libraries shared only. Every library is built as an unversioned shared
# object (Gradle only packages lib*.so) except libvpx, which is linked
# statically into libavcodec (BSD-3-Clause). All objects are hardened:
#   -D_FORTIFY_SOURCE=2 -fstack-protector-strong -fstack-clash-protection, PIC,
#   RELRO + BIND_NOW, non-executable stack, 16 KB ELF segment alignment,
#   control-flow integrity in hardware: BTI + PAC (arm64-v8a,
#   -mbranch-protection=standard) and CET (x86_64, -fcf-protection=full).
# check_elf enforces these properties on every staged object.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ $# -ge 1 ] || { echo "usage: $0 <out-dir> [abi ...]" >&2; exit 2; }
OUT="$(mkdir -p "$1" && cd "$1" && pwd)"
shift
ABIS=("$@")
[ ${#ABIS[@]} -gt 0 ] || ABIS=(arm64-v8a armeabi-v7a x86_64)

API=29
NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
[ -n "$NDK" ] && [ -f "$NDK/source.properties" ] || { echo "build: set ANDROID_NDK_HOME to NDK r28+" >&2; exit 2; }
NDK_REV="$(sed -n 's/^Pkg.Revision *= *//p' "$NDK/source.properties")"
[ "${NDK_REV%%.*}" -ge 28 ] || { echo "build: NDK $NDK_REV is older than r28" >&2; exit 2; }
WANT_NDK="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["toolchains"]["android-ndk"]["revision"])' "$ROOT/versions.json")"
[ "$NDK_REV" = "$WANT_NDK" ] || echo "build: warning: NDK $NDK_REV differs from pinned $WANT_NDK" >&2
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
[ -d "$TOOLCHAIN" ] || { echo "build: Linux host required (no $TOOLCHAIN)" >&2; exit 2; }

WORK="${MEDIAHRO_WORK:-$ROOT/build/android}"
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
SRC="$WORK/src"
JOBS="${JOBS:-$(nproc)}"
export LC_ALL=C SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1767225600}"

for tool in python3 meson ninja cmake make pkg-config nasm autoreconf patch; do
  command -v "$tool" >/dev/null || { echo "build: missing host tool $tool" >&2; exit 2; }
done
python3 -c 'import jinja2' 2>/dev/null || { echo "build: python3 jinja2 is required (libplacebo)" >&2; exit 2; }

log() { printf '\n=== [%s] %s\n' "${ABI:-*}" "$*"; }

python3 "$ROOT/scripts/verify_flags.py"
python3 "$ROOT/scripts/sources.py" fetch --platform android --dest "$SRC" --cache "$WORK/downloads" \
  ${SOURCES_SKIP:+--skip $SOURCES_SKIP}

# --- flags files ------------------------------------------------------------------

flags() {  # flags <file> → one argument per non-comment line
  local f="$ROOT/flags/$1" line
  [ -f "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    [ -z "$line" ] || [ "${line:0:1}" = "#" ] || printf '%s\n' "$line"
  done < "$f"
}

# --- per-ABI toolchain ----------------------------------------------------------------

setup_abi() {
  ABI="$1"
  case "$ABI" in
    arm64-v8a)   HOST=aarch64-linux-android;   CLANG_T=aarch64-linux-android$API;     CPU_FAMILY=aarch64; CPU=armv8-a; FF_ARCH=aarch64; FF_CPU=armv8-a; VPX_TARGET=arm64-android-gcc;  ARCH_FLAGS="-mbranch-protection=standard" ;;
    armeabi-v7a) HOST=arm-linux-androideabi;   CLANG_T=armv7a-linux-androideabi$API;  CPU_FAMILY=arm;     CPU=armv7-a; FF_ARCH=arm;     FF_CPU=armv7-a; VPX_TARGET=armv7-android-gcc;  ARCH_FLAGS="-mthumb" ;;
    x86_64)      HOST=x86_64-linux-android;    CLANG_T=x86_64-linux-android$API;      CPU_FAMILY=x86_64;  CPU=x86-64;  FF_ARCH=x86_64;  FF_CPU=x86-64;  VPX_TARGET=x86_64-android-gcc; ARCH_FLAGS="-fcf-protection=full" ;;
    *) echo "build: unknown ABI $ABI" >&2; exit 2 ;;
  esac
  BUILD="$WORK/$ABI/build"; PREFIX="$WORK/$ABI/prefix"; INFO="$WORK/$ABI/build-info"
  mkdir -p "$BUILD" "$PREFIX/lib/pkgconfig" "$PREFIX/include" "$INFO"
  export CC="$TOOLCHAIN/bin/$CLANG_T-clang" CXX="$TOOLCHAIN/bin/$CLANG_T-clang++"
  export AR="$TOOLCHAIN/bin/llvm-ar" RANLIB="$TOOLCHAIN/bin/llvm-ranlib" NM="$TOOLCHAIN/bin/llvm-nm"
  export STRIP="$TOOLCHAIN/bin/llvm-strip" READELF="$TOOLCHAIN/bin/llvm-readelf" LD="$TOOLCHAIN/bin/ld.lld"
  export OBJDUMP="$TOOLCHAIN/bin/llvm-objdump"
  local probe=""
  "$CC" -fstack-clash-protection -Werror -x c -c /dev/null -o /dev/null 2>/dev/null && probe="-fstack-clash-protection"
  # The optimisation level comes per library from opt_level (install size, docs/11 §5).
  # Size optimisations (ADR-020). Each can be switched off to measure what it buys:
  # MEDIAHRO_NO_LTO, MEDIAHRO_NO_ICF, MEDIAHRO_NO_GC, MEDIAHRO_ALL_O2 (see android/README.md).
  local lto="-flto=thin" gc="-ffunction-sections -fdata-sections" ldgc="-Wl,--gc-sections" icf="-Wl,--icf=all"
  [ -n "${MEDIAHRO_NO_LTO:-}" ] && lto=""
  [ -n "${MEDIAHRO_NO_GC:-}" ] && { gc=""; ldgc=""; }
  [ -n "${MEDIAHRO_NO_ICF:-}" ] && icf=""
  HARDEN="-fPIC -D_FORTIFY_SOURCE=2 -fstack-protector-strong $probe $ARCH_FLAGS $gc $lto"
  # FFmpeg 8 and libplacebo need newer Vulkan headers than the NDK sysroot has.
  VKINC="-I$SRC/vulkan-headers/include"
  LDHARDEN="-Wl,-z,max-page-size=16384 -Wl,-z,relro -Wl,-z,now -Wl,-z,noexecstack -Wl,--build-id=sha1 $ldgc $icf $lto"
  export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"
  unset PKG_CONFIG_PATH PKG_CONFIG_SYSROOT_DIR
  CROSS="$WORK/$ABI/meson-cross.ini"
  local q; q() { local a=() w; for w in $1; do a+=("'$w'"); done; local IFS=,; echo "[${a[*]}]"; }
  cat > "$CROSS" <<EOF
[binaries]
c = '$CC'
cpp = '$CXX'
ar = '$AR'
nm = '$NM'
strip = '$STRIP'
ranlib = '$RANLIB'
pkg-config = '$(command -v pkg-config)'
nasm = '$(command -v nasm)'

[built-in options]
c_args = $(q "$HARDEN $VKINC")
cpp_args = $(q "$HARDEN $VKINC")
c_link_args = $(q "$LDHARDEN")
cpp_link_args = $(q "$LDHARDEN")

[properties]
needs_exe_wrapper = true

[host_machine]
system = 'android'
cpu_family = '$CPU_FAMILY'
cpu = '$CPU'
endian = 'little'
EOF
  # The NDK's zlib has no .pc file; describe it so pkg-config users find it.
  cat > "$PREFIX/lib/pkgconfig/zlib.pc" <<EOF
Name: zlib
Description: zlib from the Android NDK sysroot
Version: 1.3
Libs: -lz
Cflags:
EOF
}

# --- build helpers ----------------------------------------------------------------------

# Install size (docs/11 §5): libraries off the playback / decode hot path are built with -Os.
# Decode and render hot paths (FFmpeg, dav1d, libplacebo, mpv, libass + freetype/harfbuzz/fribidi for subtitle
# rendering, image codecs, whisper) stay at -O2 so no speed budget moves (ADR-020).
SIZE_LIBS="bzip2 brotli libdeflate expat libffi pcre2 glib fontconfig uchardet libiconv
  libudfread libbluray libarchive libexif imath openexr libopenmpt libsmb2 libnfs curl libebur128 chromaprint leptonica"
opt_level() { [ -n "${MEDIAHRO_ALL_O2:-}" ] && { echo 2; return; }; [[ " $(echo $SIZE_LIBS) " == *" $1 "* ]] && echo s || echo 2; }

STEP=""; STEP_ARGS=()
should_build() {  # skip when the stamp matches (source hash + recipe args), unless ONLY names it
  local name="$1"; shift
  STEP="$name"; STEP_ARGS=("$@")
  [[ " ${SKIP:-} " == *" $name "* ]] && return 1
  local stamp="$WORK/$ABI/stamps/$name" key
  key="$(cat "$SRC/$name/.mediahro-sha256" 2>/dev/null || echo local)|$(printf '%s\n' "$@" | sha256sum | cut -c1-16)"
  if [ -n "${ONLY:-}" ]; then
    [[ " $ONLY " == *" $name "* ]] || { [ -f "$stamp" ] && return 1; }
  elif [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$key" ]; then
    return 1
  fi
  mkdir -p "$WORK/$ABI/stamps"; rm -f "$stamp"; STAMP_KEY="$key"
  log "$name"
  touch "$WORK/$ABI/.step-start"; sleep 1
  return 0
}

finish() {  # finish <name> <build-dir> → source scan, file list, build-info, stamp
  local name="$1" bdir="$2" files
  files="$(find "$PREFIX/lib" -maxdepth 1 \( -name '*.so' -o -name '*.a' \) -newer "$WORK/$ABI/.step-start" -printf '%f\n' | sort)"
  python3 "$ROOT/scripts/source_scan.py" "$name" "$SRC/$name" "$bdir" "$WORK/$ABI/scan/$name.json" $(grep '\.so$' <<<"$files" || true)
  python3 - "$INFO/$name.json" "$name" "$WORK/$ABI/scan/$name.json" "$files" "$WORK" "$NDK" "${STEP_ARGS[@]}" <<'PY'
import json, sys
out, name, scan, files, work, ndk, *args = sys.argv[1:]
s = json.load(open(scan))
# Configure lines go into the About screen: drop machine-specific paths.
args = [a.replace(work, "$WORK").replace(ndk, "$NDK") for a in args]
args = [a for a in args if "/bin/pkg-config" not in a and "/bin/nasm" not in a]
json.dump({"name": name, "configure": args, "files": [f for f in files.split() if f],
           "files_scanned": s["files_scanned"], "gpl_only_sources": s["gpl_only_sources"],
           "gpl_with_exception_sources": s["gpl_with_exception_sources"]}, open(out, "w"), indent=2)
PY
  echo "$STAMP_KEY" > "$WORK/$ABI/stamps/$name"
}

scan_into() {  # scan_into <name> <build-dir> <artefact> → build-info for a library compiled into another one
  local name="$1" bdir="$2" into="$3"
  python3 "$ROOT/scripts/source_scan.py" "$name" "$SRC/$name" "$bdir" "$WORK/$ABI/scan/$name.json" "${into%% *}"
  python3 - "$INFO/$name.json" "$name" "$WORK/$ABI/scan/$name.json" "$into" <<'PY'
import json, sys
out, name, scan, into = sys.argv[1:]
s = json.load(open(scan))
json.dump({"name": name, "configure": [f"built as part of {into}"], "files": [], "compiled_into": into,
           "files_scanned": s["files_scanned"], "gpl_only_sources": s["gpl_only_sources"],
           "gpl_with_exception_sources": s["gpl_with_exception_sources"]}, open(out, "w"), indent=2)
PY
}

header_only() {  # header_only <name> → build-info without a build (compiled into a consumer)
  local name="$1"; shift
  python3 - "$INFO/$name.json" "$name" "$@" <<'PY'
import json, sys
out, name, *args = sys.argv[1:]
json.dump({"name": name, "configure": args, "files": [], "files_scanned": 0, "gpl_only_sources": [],
           "gpl_with_exception_sources": [], "compiled_into": "consumers (headers / generated code)"}, open(out, "w"), indent=2)
PY
}

meson_build() {  # meson_build <name> [meson options...]
  local name="$1"; shift
  local opts=(--prefix "$PREFIX" --libdir lib -Doptimization="$(opt_level "$name")" -Ddebug=false -Db_ndebug=true
              --wrap-mode nodownload
              -Db_staticpic=true --cross-file "$CROSS" "$@")
  [[ " $* " == *" -Ddefault_library="* ]] || opts+=(-Ddefault_library=shared)
  should_build "$name" "${opts[@]}" || return 0
  local b="$BUILD/$name"; rm -rf "$b"
  meson setup "$b" "$SRC/$name" "${opts[@]}"
  ninja -C "$b" -j "$JOBS"
  meson install -C "$b" --no-rebuild
  finish "$name" "$b"
}

cmake_build() {  # cmake_build <name> [cmake options...]   (CMAKE_SUBDIR selects a sub-directory)
  local name="$1"; shift
  local opts; cmake_opts "$name" "$@"; opts=("${CMAKE_OPTS[@]}")
  should_build "$name" "${opts[@]}" || return 0
  local b="$BUILD/$name"; rm -rf "$b"
  cmake -S "$SRC/$name/${CMAKE_SUBDIR:-}" -B "$b" "${opts[@]}"
  cmake --build "$b" -j "$JOBS"
  cmake --install "$b"
  finish "$name" "$b"
}

cmake_opts() {  # cmake_opts <name> [cmake options...] → CMAKE_OPTS: the options every CMake build gets
  local name="$1"; shift
  CMAKE_OPTS=(-G Ninja -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake"
              -DANDROID_ABI="$ABI" -DANDROID_PLATFORM="android-$API" -DANDROID_STL=c++_shared
              -DANDROID_SUPPORT_FLEXIBLE_PAGE_SIZES=ON -DCMAKE_BUILD_TYPE=Release
              -DCMAKE_C_FLAGS_RELEASE="-O$(opt_level "$name") -DNDEBUG" -DCMAKE_CXX_FLAGS_RELEASE="-O$(opt_level "$name") -DNDEBUG"
              -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_PREFIX_PATH="$PREFIX"
              -DCMAKE_FIND_ROOT_PATH="$PREFIX" -DBUILD_SHARED_LIBS=ON -DCMAKE_POSITION_INDEPENDENT_CODE=ON
              -DCMAKE_C_FLAGS="$HARDEN" -DCMAKE_CXX_FLAGS="$HARDEN"
              -DCMAKE_SHARED_LINKER_FLAGS="$LDHARDEN" -DCMAKE_MODULE_LINKER_FLAGS="$LDHARDEN"
              -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DPKG_CONFIG_EXECUTABLE="$(command -v pkg-config)"
              -DCMAKE_ASM_NASM_COMPILER="$(command -v nasm)" "$@")
}

host_protoc() {  # host_protoc → PROTOC: protoc for the build machine, from the pinned protobuf (once per run)
  local h="$WORK/host/protobuf" stamp
  stamp="$(cat "$SRC/protobuf/.mediahro-sha256")"
  PROTOC="$h/build/protoc"
  [ -x "$PROTOC" ] && [ "$(cat "$h/stamp" 2>/dev/null)" = "$stamp" ] && return 0
  log "protobuf (host protoc)"
  rm -rf "$h"; mkdir -p "$h"
  # The host compiler, not the NDK's: clear the target toolchain variables setup_abi exported.
  env -u CC -u CXX -u AR -u RANLIB -u NM -u STRIP -u LD -u OBJDUMP -u READELF -u PKG_CONFIG_LIBDIR \
    cmake -S "$SRC/protobuf" -B "$h/build" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=cc -DCMAKE_CXX_COMPILER=c++ \
      -Dprotobuf_BUILD_TESTS=OFF -Dprotobuf_BUILD_SHARED_LIBS=OFF -Dprotobuf_WITH_ZLIB=OFF -Dprotobuf_BUILD_EXAMPLES=OFF > "$h/configure.log"
  env -u CC -u CXX -u AR -u RANLIB -u NM -u STRIP -u LD -u OBJDUMP -u READELF cmake --build "$h/build" -j "$JOBS" --target protoc
  echo "$stamp" > "$h/stamp"
}

unversion_libtool() {  # Android loads lib<name>.so only: drop libtool's soname versions
  find "$1" -name libtool -type f -exec sed -i \
    -e 's/^soname_spec=.*/soname_spec="\\$libname\\$release\\$shared_ext"/' \
    -e 's/^library_names_spec=.*/library_names_spec="\\$libname\\$release\\$shared_ext"/' {} +
}

autotools_build() {  # autotools_build <name> [configure options...]  (in a copy of the source)
  local name="$1"; shift
  local opts=(--host="$HOST" --prefix="$PREFIX" --libdir="$PREFIX/lib" --enable-shared --disable-static --with-pic "$@")
  should_build "$name" "${opts[@]}" || return 0
  local b="$BUILD/$name"; rm -rf "$b"; cp -a "$SRC/$name" "$b"
  # -MD: every compile leaves a depfile for source_scan.py, also in hand-written Makefiles (libiconv).
  (cd "$b" && CFLAGS="-O$(opt_level "$name") $HARDEN -MD" CXXFLAGS="-O$(opt_level "$name") $HARDEN -MD" CPPFLAGS="-I$PREFIX/include" \
     LDFLAGS="$LDHARDEN -L$PREFIX/lib" LIBS="$("$CC" -print-libgcc-file-name)" ./configure "${opts[@]}")
  # libtool links C++ libraries with -nostdlib: the compiler-rt builtins (LIBS above) keep
  # outline atomics and other helpers inside the library instead of leaving them undefined.
  unversion_libtool "$b"
  # AUTOTOOLS_SUBDIRS limits the build to library directories (libiconv: not its GPL `iconv` program).
  local d
  for d in ${AUTOTOOLS_SUBDIRS:-.}; do
    make -C "$b/$d" -j "$JOBS"
    make -C "$b/$d" install
  done
  [ -z "${AUTOTOOLS_POST:-}" ] || (cd "$b" && eval "$AUTOTOOLS_POST")
  finish "$name" "$b"
}

# --- recipes (dependency order) -----------------------------------------------------------

recipes() {
  local vk="$SRC/vulkan-headers"

  header_only vulkan-headers "include=$vk/include"
  header_only fast_float
  header_only glad "generator for libplacebo's OpenGL loader"

  # bzip2 ships only a Makefile: compile libbz2.so directly.
  if should_build bzip2 "cc libbz2.so"; then
    local b="$BUILD/bzip2"; rm -rf "$b"; mkdir -p "$b"
    local s
    for s in blocksort huffman crctable randtable compress decompress bzlib; do
      "$CC" -Os $HARDEN -D_FILE_OFFSET_BITS=64 -MD -MF "$b/$s.d" -c "$SRC/bzip2/$s.c" -o "$b/$s.o"
    done
    "$CC" -shared $LDHARDEN -Wl,-soname,libbz2.so -o "$PREFIX/lib/libbz2.so" "$b"/*.o
    install -m644 "$SRC/bzip2/bzlib.h" "$PREFIX/include/"
    printf 'prefix=%s\nName: bzip2\nDescription: bzip2\nVersion: 1.0.8\nLibs: -L${prefix}/lib -lbz2\nCflags: -I${prefix}/include\n' "$PREFIX" > "$PREFIX/lib/pkgconfig/bzip2.pc"
    finish bzip2 "$b"
  fi

  CMAKE_SUBDIR=build/cmake cmake_build zstd -DZSTD_BUILD_PROGRAMS=OFF -DZSTD_BUILD_STATIC=OFF -DZSTD_BUILD_SHARED=ON -DZSTD_BUILD_TESTS=OFF -DZSTD_LEGACY_SUPPORT=OFF
  cmake_build xz -DXZ_TOOL_XZ=OFF -DXZ_TOOL_XZDEC=OFF -DXZ_TOOL_LZMADEC=OFF -DXZ_TOOL_LZMAINFO=OFF -DXZ_TOOL_SCRIPTS=OFF -DXZ_TOOL_SYMLINKS=OFF -DXZ_TOOL_SYMLINKS_LZMA=OFF -DXZ_NLS=OFF -DXZ_DOC=OFF -DBUILD_TESTING=OFF
  cmake_build brotli -DBROTLI_BUILD_TOOLS=OFF -DBUILD_TESTING=OFF -DBROTLI_DISABLE_TESTS=ON
  cmake_build libdeflate -DLIBDEFLATE_BUILD_STATIC_LIB=OFF -DLIBDEFLATE_BUILD_SHARED_LIB=ON -DLIBDEFLATE_BUILD_GZIP=OFF -DLIBDEFLATE_BUILD_TESTS=OFF
  cmake_build expat -DEXPAT_BUILD_TOOLS=OFF -DEXPAT_BUILD_EXAMPLES=OFF -DEXPAT_BUILD_TESTS=OFF -DEXPAT_BUILD_DOCS=OFF -DEXPAT_BUILD_FUZZERS=OFF -DEXPAT_SHARED_LIBS=ON
  autotools_build libffi --disable-docs --disable-multi-os-directory --disable-exec-static-tramp
  cmake_build pcre2 -DPCRE2_BUILD_PCRE2GREP=OFF -DPCRE2_BUILD_TESTS=OFF -DPCRE2_SUPPORT_JIT=OFF -DPCRE2_BUILD_PCRE2_8=ON -DPCRE2_BUILD_PCRE2_16=OFF -DPCRE2_BUILD_PCRE2_32=OFF -DPCRE2_STATIC_PIC=ON
  # glib takes its libintl shim as a meson subproject (bionic has no gettext).
  # glib's wrap names the directory and pins the same tarball SHA-256 as versions.json.
  local intl_dir; intl_dir="$(sed -n 's/^directory *= *//p' "$SRC/glib/subprojects/proxy-libintl.wrap")"
  grep -q "$(python3 -c 'import json,sys;print(next(l["sha256"] for l in json.load(open(sys.argv[1]))["libraries"] if l["name"]=="proxy-libintl"))' "$ROOT/versions.json")"     "$SRC/glib/subprojects/proxy-libintl.wrap" || { echo "build: glib's proxy-libintl wrap differs from versions.json" >&2; exit 1; }
  ln -sfn "$SRC/proxy-libintl" "$SRC/glib/subprojects/$intl_dir"
  meson_build glib -Dtests=false -Dinstalled_tests=false -Dintrospection=disabled -Dnls=disabled -Dlibmount=disabled \
    -Dselinux=disabled -Dxattr=false -Dsysprof=disabled -Dman-pages=disabled -Ddocumentation=false -Ddtrace=disabled \
    -Dsystemtap=disabled -Dlibelf=disabled -Dglib_debug=disabled -Dglib_assert=false -Dglib_checks=true
  if [ ! -f "$INFO/proxy-libintl.json" ] || [ "$INFO/glib.json" -nt "$INFO/proxy-libintl.json" ]; then
    scan_into proxy-libintl "$BUILD/glib" "libintl.so (glib subproject)"
  fi

  # Text and subtitles
  meson_build freetype -Dharfbuzz=disabled -Dpng=disabled -Dbrotli=enabled -Dbzip2=enabled -Dzlib=system -Dtests=disabled
  meson_build fribidi -Ddocs=false -Dbin=false -Dtests=false
  meson_build harfbuzz -Dfreetype=enabled -Dglib=disabled -Dgobject=disabled -Dcairo=disabled -Dchafa=disabled -Dicu=disabled \
    -Dgraphite=disabled -Dgraphite2=disabled -Dfontations=disabled -Dharfrust=disabled -Dkbts=disabled -Dwasm=disabled \
    -Draster=disabled -Dvector=disabled -Dgpu=disabled -Dsubset=disabled -Dtests=disabled -Dintrospection=disabled \
    -Ddocs=disabled -Dutilities=disabled -Dbenchmark=disabled -Dpng=disabled -Dzlib=disabled
  meson_build fontconfig -Ddoc=disabled -Dnls=disabled -Dtests=disabled -Dtools=disabled -Dcache-build=disabled \
    -Dxml-backend=expat -Dfontations=disabled -Ddefault-fonts-dirs=/system/fonts
  local ass_asm=enabled; [ "$ABI" = armeabi-v7a ] && ass_asm=disabled  # libass has no 32-bit ARM assembly
  meson_build libass -Dfontconfig=enabled -Ddirectwrite=disabled -Dcoretext=disabled -Drequire-system-font-provider=false \
    -Dtest=disabled -Dcompare=disabled -Dprofile=disabled -Dfuzz=disabled -Dcheckasm=disabled -Dlibunibreak=disabled -Dasm=$ass_asm
  cmake_build uchardet -DBUILD_BINARY=OFF -DBUILD_STATIC=OFF

  # Codecs
  cmake_build libjpeg-turbo -DENABLE_STATIC=OFF -DENABLE_SHARED=ON -DWITH_TURBOJPEG=OFF -DWITH_JAVA=OFF -DWITH_TOOLS=OFF -DWITH_TESTS=OFF
  meson_build dav1d -Denable_tools=false -Denable_tests=false -Denable_examples=false -Denable_docs=false -Denable_asm=true
  # libvpx assembles with nasm on x86_64 and with the NDK clang on ARM (not the host's GNU as).
  local vpx_as=() vpx_asm="$CC -c"; [ "$ABI" = x86_64 ] && { vpx_as=(--as=nasm); vpx_asm=nasm; }
  if should_build libvpx --target="$VPX_TARGET" --enable-pic --disable-shared --enable-static --disable-examples \
       --disable-tools --disable-docs --disable-unit-tests --enable-vp9-highbitdepth --disable-runtime-cpu-detect "${vpx_as[@]}"; then
    local b="$BUILD/libvpx"; rm -rf "$b"; mkdir -p "$b"
    # No LTO for libvpx: its install strips the static archive, which llvm-strip cannot do to LTO bitcode;
    # it is mostly assembly and is linked statically into libavcodec anyway.
    (cd "$b" && CROSS="" CFLAGS="-O2 ${HARDEN//-flto=thin/}" CXXFLAGS="-O2 ${HARDEN//-flto=thin/}" \
       LDFLAGS="${LDHARDEN//-flto=thin/}" LD="$CC" AS="$vpx_asm" \
       "$SRC/libvpx/configure" --prefix="$PREFIX" --libdir="$PREFIX/lib" "${STEP_ARGS[@]}")
    make -C "$b" -j "$JOBS"
    make -C "$b" install
    finish libvpx "$b"
  fi
  cmake_build opus -DOPUS_BUILD_PROGRAMS=OFF -DOPUS_BUILD_TESTING=OFF -DOPUS_INSTALL_PKG_CONFIG_MODULE=ON -DOPUS_INSTALL_CMAKE_CONFIG_MODULE=ON
  autotools_build libopenmpt --without-mpg123 --without-ogg --without-vorbis --without-vorbisfile --without-portaudio \
    --without-portaudiocpp --without-pulseaudio --without-sndfile --without-flac --disable-openmpt123 --disable-examples \
    --disable-tests --disable-doxygen-doc

  # SPIR-V compiler for libplacebo's Vulkan backend: glslang, static and without its SPIRV-Tools optimiser or HLSL
  # front end (install size, docs/11 §5). It is linked into libplacebo.so; shaderc and SPIRV-Tools are not shipped.
  cmake_build glslang -DBUILD_SHARED_LIBS=OFF -DENABLE_OPT=OFF -DENABLE_HLSL=OFF -DENABLE_GLSLANG_BINARIES=OFF \
    -DGLSLANG_TESTS=OFF -DENABLE_CTEST=OFF -DGLSLANG_ENABLE_INSTALL=ON -DBUILD_EXTERNAL=OFF -DENABLE_SPVREMAPPER=OFF
  meson_build lcms2 -Djpeg=disabled -Dtiff=disabled -Dutils=false -Dfastfloat=false -Dthreaded=false -Dtests=disabled -Dversionedlibs=false

  # libplacebo: provide its git submodules from pinned sources
  local pl="$SRC/libplacebo/3rdparty"; mkdir -p "$pl"
  for sub in glad:glad fast_float:fast_float Vulkan-Headers:vulkan-headers; do
    rm -rf "${pl:?}/${sub%%:*}"; ln -sfn "$SRC/${sub##*:}" "$pl/${sub%%:*}"
  done
  # Platform flags override shared ones with the same -D key (meson rejects a key given twice).
  mapfile -t PL_FLAGS < <(flags libplacebo.flags; flags libplacebo.android.flags | sed 's/^/@/')
  PL_FLAGS=($(python3 -c 'import sys
out = {}
for a in sys.argv[1:]:
    k = a.lstrip("@").split("=", 1)[0]
    if a.startswith("@") or k not in out:
        out[k] = a.lstrip("@")
print(*out.values())' "${PL_FLAGS[@]}"))
  # glslang is a static C++ library in the prefix. glslang 16 keeps all of it in libglslang.a (SPIRV and
  # MachineIndependent are empty stubs), which libplacebo's probe does not add itself.
  meson_build libplacebo "${PL_FLAGS[@]}" -Dvulkan-registry="$vk/registry/vk.xml" \
    -Dc_args="$HARDEN $VKINC -I$PREFIX/include" -Dcpp_args="$HARDEN $VKINC -I$PREFIX/include" \
    -Dc_link_args="$LDHARDEN -L$PREFIX/lib -lglslang -lglslang-default-resource-limits" -Dcpp_link_args="$LDHARDEN -L$PREFIX/lib -lglslang -lglslang-default-resource-limits" -Dprefer_static=true -Dvulkan-sdk="$PREFIX"

  # Archives (libvips dzsave/archive loader and the app's archive browser)
  cmake_build libarchive -DENABLE_OPENSSL=OFF -DENABLE_MBEDTLS=OFF -DENABLE_NETTLE=OFF -DENABLE_LIBB2=OFF -DENABLE_LZ4=OFF \
    -DENABLE_LZO=OFF -DENABLE_LIBXML2=OFF -DENABLE_EXPAT=OFF -DENABLE_PCREPOSIX=OFF -DENABLE_PCRE2POSIX=OFF -DENABLE_CNG=OFF \
    -DENABLE_TAR=OFF -DENABLE_CPIO=OFF -DENABLE_CAT=OFF -DENABLE_UNZIP=OFF -DENABLE_TEST=OFF -DENABLE_ACL=OFF -DENABLE_XATTR=OFF \
    -DENABLE_ICONV=ON -DENABLE_ZSTD=ON -DENABLE_LZMA=ON -DENABLE_BZip2=ON -DENABLE_ZLIB=ON -DENABLE_WERROR=OFF

  # Image pipeline
  cmake_build libspng -DSPNG_SHARED=ON -DSPNG_STATIC=OFF -DBUILD_EXAMPLES=OFF
  cmake_build libwebp -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF -DWEBP_BUILD_GIF2WEBP=OFF \
    -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF -DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF \
    -DWEBP_BUILD_LIBWEBPMUX=ON -DWEBP_ENABLE_SWAP_16BIT_CSP=OFF
  cmake_build libtiff -Dtiff-tools=OFF -Dtiff-tests=OFF -Dtiff-contrib=OFF -Dtiff-docs=OFF -Djpeg=ON -Dzlib=ON -Dlibdeflate=ON \
    -Dlzma=ON -Dzstd=ON -Dwebp=ON -Djbig=OFF -Dlerc=OFF -Dtiff-cxx=OFF -Dold-jpeg=OFF
  cmake_build highway -DHWY_ENABLE_TESTS=OFF -DHWY_ENABLE_EXAMPLES=OFF -DHWY_ENABLE_CONTRIB=OFF -DHWY_ENABLE_INSTALL=ON -DBUILD_TESTING=OFF
  cmake_build libjxl -DJPEGXL_ENABLE_TOOLS=OFF -DJPEGXL_ENABLE_DOXYGEN=OFF -DJPEGXL_ENABLE_MANPAGES=OFF -DJPEGXL_ENABLE_BENCHMARK=OFF \
    -DJPEGXL_ENABLE_EXAMPLES=OFF -DJPEGXL_ENABLE_JPEGLI=OFF -DJPEGXL_ENABLE_SJPEG=OFF -DJPEGXL_ENABLE_OPENEXR=OFF \
    -DJPEGXL_ENABLE_SKCMS=OFF -DJPEGXL_FORCE_SYSTEM_BROTLI=ON -DJPEGXL_FORCE_SYSTEM_HWY=ON -DJPEGXL_FORCE_SYSTEM_LCMS2=ON \
    -DJPEGXL_ENABLE_PLUGINS=OFF -DJPEGXL_BUNDLE_LIBPNG=OFF -DJPEGXL_ENABLE_JNI=OFF -DJPEGXL_ENABLE_FUZZERS=OFF \
    -DJPEGXL_ENABLE_DEVTOOLS=OFF -DBUILD_TESTING=OFF -DJPEGXL_ENABLE_TRANSCODE_JPEG=ON
  cmake_build imath -DBUILD_TESTING=OFF -DIMATH_INSTALL_PKG_CONFIG=ON -DPYTHON=OFF -DIMATH_INSTALL_TOOLS=OFF
  cmake_build openexr -DOPENEXR_BUILD_TOOLS=OFF -DOPENEXR_INSTALL_TOOLS=OFF -DOPENEXR_INSTALL_EXAMPLES=OFF -DOPENEXR_BUILD_EXAMPLES=OFF \
    -DBUILD_TESTING=OFF -DOPENEXR_FORCE_INTERNAL_DEFLATE=OFF -DOPENEXR_FORCE_INTERNAL_IMATH=OFF -DOPENEXR_BUILD_PYTHON=OFF \
    -DOPENEXR_INSTALL_PKG_CONFIG=ON -DOPENEXR_ENABLE_THREADING=ON
  # AV1 encoder for AVIF export (IMG-010, ADR-037; dav1d decodes): libaom, encoder only, linked statically into
  # libavif.so so no extra library ships. -O2 (speed of batch convert); good-quality/all-intra modes need
  # CONFIG_REALTIME_ONLY=0 and 10-bit (HDR AVIF) needs CONFIG_AV1_HIGHBITDEPTH=1, so neither is trimmed (ADR-020).
  # CPU features come from getauxval (API >= 18), so NDK cpu-features is dead code; x86_64 SIMD is assembled by nasm.
  cmake_build libaom -DBUILD_SHARED_LIBS=OFF -DENABLE_APPS=OFF -DENABLE_EXAMPLES=OFF -DENABLE_TESTS=OFF -DENABLE_TESTDATA=OFF \
    -DENABLE_TOOLS=OFF -DENABLE_DOCS=OFF -DENABLE_NASM=ON -DCONFIG_AV1_DECODER=0 -DCONFIG_AV1_ENCODER=1 \
    -DCONFIG_AV1_HIGHBITDEPTH=1 -DCONFIG_REALTIME_ONLY=0 -DCONFIG_RUNTIME_CPU_DETECT=1 -DCONFIG_MULTITHREAD=1 \
    -DCONFIG_WEBM_IO=0 -DCONFIG_TUNE_VMAF=0 -DCONFIG_TUNE_BUTTERAUGLI=0 -DCONFIG_AV1_TEMPORAL_DENOISING=0
  # --exclude-libs,ALL keeps libaom's symbols out of libavif.so's exports (only avif* is public).
  cmake_build libavif -DAVIF_CODEC_DAV1D=SYSTEM -DAVIF_CODEC_AOM=SYSTEM -DAVIF_CODEC_AOM_DECODE=OFF -DAVIF_CODEC_AOM_ENCODE=ON \
    -DAVIF_LIBYUV=OFF -DAVIF_BUILD_APPS=OFF -DAVIF_BUILD_TESTS=OFF -DAVIF_JPEG=OFF -DAVIF_ZLIBPNG=OFF -DAVIF_LIBSHARPYUV=OFF \
    -DAVIF_LIBXML2=OFF -DAVIF_BUILD_EXAMPLES=OFF -DCMAKE_SHARED_LINKER_FLAGS="$LDHARDEN -Wl,--exclude-libs,ALL"
  autotools_build libexif --disable-docs --disable-nls
  autotools_build libraw --disable-examples --disable-openmp --enable-lcms --enable-jpeg --disable-jasper --enable-zlib
  mapfile -t VIPS_FLAGS < <(flags vips.flags; flags vips.android.flags)
  meson_build libvips "${VIPS_FLAGS[@]}"

  # SUB-013: bionic's iconv only converts UTF-8/16/32, ASCII and Latin-1. GNU libiconv (LGPL, shared) gives mpv and
  # FFmpeg cp1251, Shift-JIS, GBK, Big5, EUC-KR and the rest. Only its library directories are built (not the GPL
  # `iconv` program). It is built right before FFmpeg: libraries built earlier (glib, fontconfig, ...) must not see
  # its iconv.h, which renames iconv() to libiconv() and needs a -liconv they do not pass.
  AUTOTOOLS_SUBDIRS="libcharset lib" AUTOTOOLS_POST='install -m644 include/iconv.h.inst "$PREFIX/include/iconv.h"' \
    autotools_build libiconv --disable-nls --enable-extra-encodings

  # FFmpeg
  mapfile -t FF_FLAGS < <(flags ffmpeg.common.flags; flags ffmpeg.android.flags)
  local ff_x86=(); [ "$ABI" = x86_64 ] && ff_x86=(--x86asmexe=nasm)
  [ "$ABI" = armeabi-v7a ] && ff_x86=(--enable-neon --enable-thumb)
  # GNU libiconv (SUB-013): FFmpeg's configure check links without -liconv, which left libavcodec with
  # undefined libiconv_* symbols and no DT_NEEDED; link it explicitly.
  ff_x86+=(--extra-libs=-liconv)
  if should_build ffmpeg "${FF_FLAGS[@]}" --arch="$FF_ARCH" --cpu="$FF_CPU" "${ff_x86[@]}"; then
    local b="$BUILD/ffmpeg"; rm -rf "$b"; mkdir -p "$b"
    (cd "$b" && "$SRC/ffmpeg/configure" --prefix="$PREFIX" --libdir="$PREFIX/lib" --shlibdir="$PREFIX/lib" \
       --cc="$CC" --cxx="$CXX" --ar="$AR" --nm="$NM" --ranlib="$RANLIB" --strip="$STRIP" \
       --pkg-config="$(command -v pkg-config)" "${STEP_ARGS[@]}" \
       --extra-cflags="$HARDEN -I$vk/include -I$PREFIX/include" --extra-cxxflags="$HARDEN" \
       --extra-ldflags="$LDHARDEN -L$PREFIX/lib" --optflags=-O2 ) > "$b/configure.out" 2>&1 \
       || { cat "$b/configure.out"; tail -50 "$b/ffbuild/config.log"; exit 1; }
    # --disable-everything makes every component explicit: a misspelt name must not drop a format silently.
    if grep -E "did not match anything|Unknown option" "$b/configure.out"; then echo "build: fix the FFmpeg flags above" >&2; exit 1; fi
    # configure drops one wrong name inside a list silently: check every requested component by name.
    python3 "$ROOT/scripts/ffmpeg_components.py" --configure "$SRC/ffmpeg/configure" "$b/config_components.h" "${STEP_ARGS[@]}"
    make -C "$b" -j "$JOBS"
    make -C "$b" install
    finish ffmpeg "$b"
  fi

  # Blu-ray (unencrypted BDMV only; no BD-J)
  meson_build libudfread
  meson_build libbluray -Dbdj_jar=disabled -Denable_tools=false -Denable_devtools=false -Denable_examples=false -Denable_docs=false \
    -Dfreetype=enabled -Dfontconfig=enabled -Dlibxml2=disabled -Dembed_udfread=false

  # mpv (libmpv only)
  mapfile -t MPV_FLAGS < <(flags mpv.flags; flags mpv.android.flags)
  # meson's iconv dependency would take bionic's: point mpv at GNU libiconv (header + -liconv) for SUB-013.
  meson_build mpv "${MPV_FLAGS[@]}" -Dc_args="$HARDEN $VKINC -I$PREFIX/include"     -Dc_link_args="$LDHARDEN -L$PREFIX/lib -liconv"


  # Sources and archives (TLS: none on Android, I/O reaches curl through the app's stream callbacks)
  cmake_build libsmb2 -DENABLE_EXAMPLES=OFF -DENABLE_LIBKRB5=OFF -DENABLE_GSSAPI=OFF -DBUILD_SHARED_LIBS=ON
  cmake_build libnfs -DENABLE_TESTS=OFF -DENABLE_DOCUMENTATION=OFF -DENABLE_UTILS=OFF -DENABLE_EXAMPLES=OFF -DENABLE_MULTITHREADING=OFF
  cmake_build curl -DCURL_ENABLE_SSL=OFF -DCURL_USE_OPENSSL=OFF -DCURL_USE_MBEDTLS=OFF -DCURL_USE_WOLFSSL=OFF -DCURL_USE_GNUTLS=OFF \
    -DCURL_USE_RUSTLS=OFF -DCURL_USE_LIBSSH2=OFF -DCURL_USE_LIBSSH=OFF -DCURL_USE_GSSAPI=OFF -DUSE_LIBIDN2=OFF -DCURL_USE_LIBPSL=OFF \
    -DUSE_NGHTTP2=OFF -DUSE_NGTCP2=OFF -DCURL_BROTLI=ON -DCURL_ZSTD=ON -DCURL_ZLIB=ON -DBUILD_CURL_EXE=OFF -DBUILD_TESTING=OFF \
    -DBUILD_LIBCURL_DOCS=OFF -DBUILD_MISC_DOCS=OFF -DENABLE_CURL_MANUAL=OFF -DCURL_DISABLE_LDAP=ON -DCURL_DISABLE_LDAPS=ON \
    -DENABLE_ARES=OFF -DCURL_CA_BUNDLE=none -DCURL_CA_PATH=none -DBUILD_STATIC_LIBS=OFF

  # Audio analysis and speech
  cmake_build libebur128 -DBUILD_STATIC_LIBS=OFF -DENABLE_TESTS=OFF
  cmake_build chromaprint -DFFT_LIB=avtx -DBUILD_TOOLS=OFF -DBUILD_TESTS=OFF
  local ggml=(-DGGML_NATIVE=OFF -DGGML_OPENMP=OFF)
  [ "$ABI" = x86_64 ] && ggml+=(-DGGML_AVX=OFF -DGGML_AVX2=OFF -DGGML_FMA=OFF -DGGML_F16C=OFF -DGGML_BMI2=OFF -DGGML_SSE42=ON)
  cmake_build whisper.cpp -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF -DWHISPER_SDL2=OFF \
    -DWHISPER_CURL=OFF "${ggml[@]}"
  # OCR fallback for SUB-051 (ADR-025 §5). Leptonica reads through the shipped libjpeg-turbo, libtiff, libwebp
  # and the system zlib; PNG is off (no libpng is shipped, spng has another API), as are GIF and OpenJPEG.
  cmake_build leptonica -DBUILD_PROG=OFF -DENABLE_PNG=OFF -DENABLE_GIF=OFF -DENABLE_OPENJPEG=OFF \
    -DENABLE_JPEG=ON -DENABLE_TIFF=ON -DENABLE_WEBP=ON -DENABLE_ZLIB=ON -DSW_BUILD=OFF
  # libtesseract and its C API only: no training tools (ICU, pango), libarchive, curl, OpenMP or ScrollView. Images
  # arrive as pixels through Leptonica, so Tesseract's own libtiff input is off. Language data is downloaded by the app.
  cmake_build tesseract -DBUILD_TRAINING_TOOLS=OFF -DBUILD_TESTS=OFF -DDISABLE_ARCHIVE=ON -DDISABLE_CURL=ON -DDISABLE_TIFF=ON \
    -DOPENMP_BUILD=OFF -DGRAPHICS_DISABLED=ON -DENABLE_NATIVE=OFF -DINSTALL_CONFIGS=OFF -DENABLE_CCACHE=OFF \
    -DENABLE_PRECOMPILED_HEADERS=OFF -DSW_BUILD=OFF -DLeptonica_DIR="$PREFIX/lib/cmake/leptonica" \
    -DLEPT_TIFF_RESULT=0  # cross build: Tesseract's Leptonica TIFF probe cannot run

  # Language identification and translation (ADR-034, SUB-051/053): CLD3 and Bergamot, each a shared library that
  # exports only lane C1's C API (shims/: mh_cld3_*, mh_bergamot_*). Static dependencies inside them are linked with
  # --exclude-libs,ALL so nothing else leaks (libcld3's protobuf 21.12 and libbergamot's protobuf-lite 3.6.1 stay apart).
  host_protoc
  cmake_build protobuf -Dprotobuf_BUILD_TESTS=OFF -Dprotobuf_BUILD_PROTOC_BINARIES=OFF -Dprotobuf_BUILD_LIBPROTOC=OFF \
    -Dprotobuf_BUILD_SHARED_LIBS=OFF -Dprotobuf_WITH_ZLIB=OFF -Dprotobuf_BUILD_EXAMPLES=OFF -Dprotobuf_INSTALL=ON
  local cld3_srcs=(base embedding_feature_extractor embedding_network feature_extractor feature_types fml_parser
    language_identifier_features lang_id_nn_params nnet_language_identifier registry relevant_script_feature
    sentence_features task_context task_context_params unicodetext utils workspace script_span/generated_entities
    script_span/getonescriptspan script_span/utf8statetable script_span/offsetmap script_span/text_processing
    script_span/fixunicodevalue)
  local shimflags="-std=c++17 -O2 $HARDEN -fvisibility=hidden -fvisibility-inlines-hidden"
  # CLD3's CMakeLists builds a static library and its tests against a system protobuf; compile it directly instead.
  if should_build cld3 "protoc $("$PROTOC" --version)" "$shimflags" "${cld3_srcs[@]}" "shim $(sha256sum "$ROOT/shims/cld3/"* | sha256sum | cut -c1-16)"; then
    local b="$BUILD/cld3" f; rm -rf "$b"; mkdir -p "$b/cld_3/protos" "$b/obj"
    "$PROTOC" --cpp_out="$b/cld_3/protos" -I"$SRC/cld3/src" "$SRC"/cld3/src/{feature_extractor,sentence,task_spec}.proto
    {
      for f in "${cld3_srcs[@]}"; do echo "$SRC/cld3/src/$f.cc"; done
      ls "$b"/cld_3/protos/*.pb.cc
      echo "$ROOT/shims/cld3/mediahro_cld3.cc"
    } | xargs -P "$JOBS" -I{} sh -c 'o="$1/obj/$(echo "$2" | sha256sum | cut -c1-16).o"; $CXX $3 -I"$1" -I"$4" -I"$5" -I"$6" -MD -MF "${o%.o}.d" -c "$2" -o "$o"' \
        _ "$b" {} "$shimflags" "$SRC/cld3/src" "$PREFIX/include" "$ROOT/shims/cld3"
    "$CXX" -shared $LDHARDEN -Wl,--exclude-libs,ALL -Wl,-soname,libcld3.so -o "$PREFIX/lib/libcld3.so" "$b"/obj/*.o \
      "$PREFIX/lib/libprotobuf-lite.a" -llog
    install -m644 "$ROOT/shims/cld3/mediahro_cld3.h" "$PREFIX/include/"
    finish cld3 "$b"
  fi

  # Bergamot: bergamot-translator's CMake builds Marian, SentencePiece, ssplit and the GEMM back ends as static
  # libraries; the submodule directories are linked to their pinned sources. ARM uses ruy (int8 and SGEMM, with
  # simd_utils); x86_64 uses intgemm with run-time ISA dispatch and ruy SGEMM, so no BLAS (MKL is proprietary) is needed.
  # Marian turns USE_RUY on by itself only for ARM; without it x86_64 never builds ruy's AVX kernels and libbergamot.so
  # leaves ruy::KernelFloatAvx* undefined, so USE_RUY is set for every ABI.
  local bt="$SRC/bergamot-translator" mr="$SRC/marian-dev" sub
  for sub in 3rd_party/marian-dev:marian-dev 3rd_party/ssplit-cpp:ssplit-cpp; do
    rm -rf "${bt:?}/${sub%%:*}"; ln -sfn "$SRC/${sub##*:}" "$bt/${sub%%:*}"
  done
  for sub in sentencepiece intgemm ruy simd_utils; do rm -rf "${mr:?}/src/3rd_party/$sub"; ln -sfn "$SRC/$sub" "$mr/src/3rd_party/$sub"; done
  rm -rf "$SRC/ruy/third_party/cpuinfo"; ln -sfn "$SRC/cpuinfo" "$SRC/ruy/third_party/cpuinfo"
  local barch; case "$ABI" in arm64-v8a) barch=armv8-a ;; armeabi-v7a) barch=armv7-a ;; x86_64) barch=x86-64 ;; esac
  cmake_opts bergamot-translator -DBUILD_SHARED_LIBS=OFF -DCOMPILE_WASM=OFF -DUSE_WASM_COMPATIBLE_SOURCE=OFF -DCOMPILE_TESTS=OFF \
    -DCOMPILE_UNIT_TESTS=OFF -DCOMPILE_PYTHON=OFF -DGIT_SUBMODULE=OFF -DBUILD_ARCH="$barch" -DCOMPILE_CUDA=OFF -DUSE_MKL=OFF \
    -DUSE_FBGEMM=OFF -DUSE_RUY=ON -DUSE_RUY_SGEMM=ON -DUSE_SENTENCEPIECE=ON -DUSE_STATIC_LIBS=ON -DCOMPILE_LIBRARY_ONLY=ON -DCOMPILE_SERVER=OFF \
    -DUSE_DOXYGEN=OFF -DSSPLIT_USE_INTERNAL_PCRE2=OFF -DSSPLIT_COMPILE_LIBRARY_ONLY=ON -DUSE_NCCL=OFF -DUSE_CUDNN=OFF \
    -DSPM_ENABLE_SHARED=OFF -DSPM_ENABLE_TCMALLOC=OFF \
    -DMARIAN_GIT_REVISION="$(python3 -c 'import json,sys;print(next(l["version"] for l in json.load(open(sys.argv[1]))["libraries"] if l["name"]=="marian-dev"))' "$ROOT/versions.json")"
  if should_build bergamot-translator "${CMAKE_OPTS[@]}" "shim $(sha256sum "$ROOT/shims/bergamot/"* | sha256sum | cut -c1-16)"; then
    local b="$BUILD/bergamot-translator"; rm -rf "$b"
    cmake -S "$bt" -B "$b" "${CMAKE_OPTS[@]}"
    # Marian's translation units need ~2 GB each with ThinLTO: cap the jobs by memory (7 GB WSL hosts, 16 GB runners).
    local mem_jobs; mem_jobs=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 2000000 )); [ "$mem_jobs" -ge 1 ] || mem_jobs=1
    cmake --build "$b" -j "$(( mem_jobs < JOBS ? mem_jobs : JOBS ))" --target bergamot-translator
    # The shim needs exactly Marian's defines and include paths (ARM/FMA/SSE for simd_utils, USE_RUY_SGEMM, ...): compile
    # it with the command CMake generated for one of bergamot-translator's own sources, with hidden visibility added.
    local svc; svc="$(ninja -C "$b" -t targets all | grep -o '^[^:]*translator/[^:]*/service.cpp.o' | head -1)"
    python3 - "$(ninja -C "$b" -t commands "$svc" | tail -1)" "$ROOT/shims/bergamot" "$b" <<'PY' > "$b/shim.sh"
import shlex, sys
cmd, shims, b = sys.argv[1], sys.argv[2], sys.argv[3]
cmd = cmd.split("&&")[-1].strip()           # ninja may prefix "cd <dir> &&"
args, out, skip = shlex.split(cmd), [], None
for a in args:
    if skip:
        skip = None
        continue
    if a in ("-o", "-c", "-MF", "-MT", "-MQ"):
        skip = a
        continue
    if a in ("-MD", "-MMD") or a.endswith("service.cpp"):
        continue
    out.append(a)
out += ["-fvisibility=hidden", "-fvisibility-inlines-hidden", "-I" + shims,
        "-MD", "-MF", b + "/mediahro_bergamot.d", "-c", shims + "/mediahro_bergamot.cc", "-o", b + "/mediahro_bergamot.o"]
print(shlex.join(out))
PY
    (cd "$b" && sh "$b/shim.sh")
    "$CXX" -shared $LDHARDEN -Wl,--exclude-libs,ALL -Wl,-soname,libbergamot.so -o "$PREFIX/lib/libbergamot.so" \
      "$b/mediahro_bergamot.o" -Wl,--start-group $(find "$b" -name '*.a' | sort) -Wl,--end-group \
      -L"$PREFIX/lib" -lpcre2-8 -llog -lz
    install -m644 "$ROOT/shims/bergamot/mediahro_bergamot.h" "$PREFIX/include/"
    finish bergamot-translator "$b"
    for sub in marian-dev ssplit-cpp sentencepiece intgemm ruy cpuinfo simd_utils; do
      scan_into "$sub" "$b" "libbergamot.so (bergamot-translator, static)"
    done
  fi
}

# --- staging, checks, packaging ---------------------------------------------------------------

# Installed by their build systems but neither linked by another library nor loaded by the app through FFI
# (mediahro packages/mediahro_ffi NativeLibrary): left out of the archive (install size, docs/11 §5).
DROP_LIBS="libSPIRV-Tools-shared.so libgirepository-2.0.so libgthread-2.0.so libpcre2-posix.so libparakeet.so libraw_r.so libwebpdecoder.so"
ANDROID_SYSTEM_LIBS="libc.so libm.so libdl.so liblog.so libz.so libandroid.so libmediandk.so libvulkan.so libEGL.so libGLESv2.so libGLESv3.so libOpenSLES.so libaaudio.so libjnigraphics.so libc++_shared.so"

check_elf() {  # check_elf <dir> → every .so is hardened, 16 KB aligned, unversioned, and needs only shipped or system libs
  local dir="$1" so errs=0 shipped
  # 16 KB pages exist only on 64-bit devices; the NDK's 32-bit libc++_shared.so is 4 KB-aligned.
  # Everything built here is linked with max-page-size=16384 on every ABI.
  local MIN_ALIGN=16384; [ "$ABI" = armeabi-v7a ] && MIN_ALIGN=4096
  shipped="$(cd "$dir" && ls *.so | tr '\n' ' ')"
  for so in "$dir"/*.so; do
    local n; n="$(basename "$so")"
    local hdr dyn segs; hdr="$("$READELF" -lW "$so")"; dyn="$("$READELF" -dW "$so")"
    while read -r align; do
      [ $((align)) -ge "$MIN_ALIGN" ] || { echo "elf: $n LOAD segment aligned $align (< $MIN_ALIGN)"; errs=$((errs+1)); }
    done < <(awk '$1=="LOAD"{print $NF}' <<<"$hdr")
    grep -q GNU_RELRO <<<"$hdr" || { echo "elf: $n has no RELRO"; errs=$((errs+1)); }
    grep -qE 'BIND_NOW|FLAGS_1.*NOW' <<<"$dyn" || { echo "elf: $n is not BIND_NOW"; errs=$((errs+1)); }
    if grep -E 'GNU_STACK' <<<"$hdr" | grep -q 'RWE'; then echo "elf: $n has an executable stack"; errs=$((errs+1)); fi
    grep -q TEXTREL <<<"$dyn" && { echo "elf: $n has text relocations"; errs=$((errs+1)); }
    local undef; undef="$("$NM" -D --undefined-only "$so" | awk '{print $NF}' | grep -E '^__(aarch64_|emutls_|clear_cache$)' | head -3 || true)"
    [ -z "$undef" ] || { echo "elf: $n leaves compiler-rt builtins undefined: $undef"; errs=$((errs+1)); }
    local soname; soname="$(sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p' <<<"$dyn")"
    [ "$soname" = "$n" ] || { echo "elf: $n SONAME is '$soname'"; errs=$((errs+1)); }
    local need
    for need in $(sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' <<<"$dyn"); do
      [[ " $shipped $ANDROID_SYSTEM_LIBS " == *" $need "* ]] || { echo "elf: $n needs $need (not shipped, not an NDK system library)"; errs=$((errs+1)); }
      [[ "$need" =~ ^lib(ssl|crypto|gnutls|mbed|wolfssl|boringssl) ]] && { echo "elf: $n links TLS library $need"; errs=$((errs+1)); }
    done
    if [ "$ABI" = arm64-v8a ]; then
      grep -qi 'aarch64 feature: BTI, PAC' <<<"$("$READELF" -nW "$so")" || echo "elf: note: $n lacks BTI/PAC property (an object was built without -mbranch-protection)"
    fi
  done
  return $errs
}

stage_abi() {
  local st="$WORK/$ABI/staging"
  rm -rf "$st"; mkdir -p "$st/lib" "$st/include" "$st/licenses" "$st/build-info"
  local f
  # Only the shared objects this build recorded (build-info "files"), never leftovers in the prefix.
  local name
  for name in $(python3 -c 'import json,sys,pathlib
for p in sorted(pathlib.Path(sys.argv[1]).glob("*.json")):
    print(*[f for f in json.loads(p.read_text()).get("files", []) if f.endswith(".so")])' "$INFO"); do
    [[ " $DROP_LIBS " == *" $name "* ]] && continue
    [ -L "$PREFIX/lib/$name" ] && continue  # e.g. libOpenEXR.so -> libOpenEXR-3_5.so: ship the real file once
    cp "$PREFIX/lib/$name" "$st/lib/"
  done
  cp "$TOOLCHAIN/sysroot/usr/lib/$HOST/libc++_shared.so" "$st/lib/"
  for f in "$st"/lib/*.so; do "$STRIP" --strip-unneeded "$f"; done
  cp -a "$PREFIX/include/." "$st/include/"
  cp "$INFO"/*.json "$st/build-info/"
  python3 - "$st/build-info" $DROP_LIBS <<'PY'
import json, pathlib, sys
drop = set(sys.argv[2:])
for p in pathlib.Path(sys.argv[1]).glob("*.json"):
    d = json.loads(p.read_text())
    gone = sorted(drop & set(d.get("files", [])))
    if gone:
        d["files"] = [f for f in d["files"] if f not in drop]
        d["not_shipped"] = gone
        p.write_text(json.dumps(d, indent=2))
PY
  # Licence texts: LGPL/permissive texts only, never a GPL text for a component taken under another licence.
  local lic name
  declare -A LIC=(
    [ffmpeg]="LICENSE.md COPYING.LGPLv2.1" [mpv]="Copyright LICENSE.LGPL" [flac]="COPYING.Xiph" [freetype]="LICENSE.TXT docs/FTL.TXT"
    [libnfs]="COPYING LICENCE-LGPL-2.1.txt LICENCE-BSD.txt" [libraw]="LICENSE.CDDL COPYRIGHT" [xz]="COPYING COPYING.0BSD"
    [zstd]="LICENSE" [libsmb2]="COPYING LICENCE-LGPL-2.1.txt" [fast_float]="LICENSE-MIT LICENSE-APACHE LICENSE-BOOST"
    [libffi]="LICENSE" [pcre2]="LICENCE.md" [leptonica]="leptonica-license.txt" [tesseract]="LICENSE"
    [marian-dev]="LICENSE.md" [ssplit-cpp]="LICENSE.md"
    [libaom]="LICENSE PATENTS third_party/libyuv/LICENSE third_party/fastfeat/LICENSE third_party/x86inc/LICENSE third_party/vector/LICENSE"
  )
  for f in "$INFO"/*.json; do
    name="$(basename "$f" .json)"
    {
      if [ -n "${LIC[$name]:-}" ]; then
        for lic in ${LIC[$name]}; do echo "==> $lic <=="; cat "$SRC/$name/$lic"; echo; done
      else
        for lic in "$SRC/$name"/{COPYING,COPYING.*,LICENSE,LICENSE.*,LICENCE,LICENCE.*,COPYRIGHT,Copyright,NOTICE}; do
          [ -f "$lic" ] || continue
          [[ "$(basename "$lic")" =~ (^|[^L])GPL ]] && continue
          echo "==> $(basename "$lic") <=="; cat "$lic"; echo
        done
      fi
    } > "$st/licenses/$name.txt"
    [ -s "$st/licenses/$name.txt" ] || { echo "build: no licence text found for $name" >&2; exit 1; }
  done
  { echo "libc++ (Android NDK $NDK_REV): Apache-2.0 WITH LLVM-exception"; head -c 200000 "$NDK/NOTICE" 2>/dev/null || true; } > "$st/licenses/libc++.txt"
  check_elf "$st/lib"
  python3 "$ROOT/scripts/elf_symbols.py" "$st/lib" "$TOOLCHAIN/sysroot/usr/lib/$HOST/$API" "$NM" "$READELF"
  local gpl
  gpl="$(python3 - "$st/build-info" <<'PY'
import json, pathlib, sys
bad = [f"{p.stem}: {s}" for p in pathlib.Path(sys.argv[1]).glob("*.json") for s in json.loads(p.read_text())["gpl_only_sources"]]
print("\n".join(bad))
PY
)"
  [ -z "$gpl" ] || { echo "build: GPL-only sources compiled:"; echo "$gpl"; exit 1; } >&2
  python3 "$ROOT/scripts/package.py" "android-$ABI" "$st" "$OUT"
}

for abi in "${ABIS[@]}"; do
  setup_abi "$abi"
  recipes
  stage_abi
done
log "done: $(ls "$OUT")"
