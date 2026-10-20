# shellcheck shell=bash
# One build_<name> function per library, run once per slice in RECIPES order.
# Every library is built shared so it can become its own .framework.

RECIPES="libffi pcre2 glib expat brotli highway opus libvpx dav1d
freetype fribidi harfbuzz libass lcms2 libjpeg-turbo libspng libwebp libdeflate zstd xz libtiff
imath openexr libexif libjxl libavif libraw uchardet libebur128 libudfread libbluray
libopenmpt libsmb2 libnfs curl libarchive chromaprint whisper.cpp libvips vulkan-headers
moltenvk glslang libplacebo ffmpeg mpv"

# Pinned libraries built inside another recipe (their own build-info says where).
COMPILED_IN="proxy-libintl spirv-cross cereal fast_float glad"

# ADR-020, as on Android: libplacebo compiles GLSL with a static glslang, so
# shaderc / SPIRV-Tools / SPIRV-Headers are not needed; FFmpeg decodes FLAC
# itself and libvips has no GIF saver, so libogg / libFLAC / cgif have no user.
# versions.json still lists them for Apple until lane B4a drops "apple" there;
# until then package.py reports them under not_built.
APPLE_NOT_BUILT="shaderc spirv-tools spirv-headers libogg flac cgif"

# new_dylibs GLOB : dylibs installed by the current recipe whose name matches GLOB
new_dylibs() {
  local f out=""
  for f in "$PREFIX"/lib/$1; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    [[ $'\n'"$BEFORE_DYLIBS"$'\n' == *$'\n'"$f"$'\n'* ]] && continue
    out+="${f##*/} "
  done
  printf '%s\n' "$out"
}

# scan_into NAME SRC_DIR BUILD_DIR CONSUMER_GLOB : build-info for a pinned
# library compiled into another library's dylib (not a framework of its own)
scan_into() {
  local name=$1 sdir=$2 bdir=$3 libs
  libs=$(new_dylibs "$4")
  [ -n "${libs// /}" ] || die "scan_into $name: no dylib matches $4"
  (STEP_ARGS=("compiled into $(fw_name "${libs%% *}")"); SCAN_LIBS="$libs" \
    finish "$name" "$bdir" "$sdir" "$(fw_name "${libs%% *}").framework")
}

# --- glib (libvips dependency) ------------------------------------------------

build_libffi() {
  local s; s=$(src libffi)
  autotools_build libffi "$s" --disable-docs --disable-multi-os-directory
  license libffi "$s/LICENSE"
}

build_pcre2() {
  local s; s=$(src pcre2)
  # No JIT: iOS forbids writable+executable pages and the macOS hardened runtime
  # would need the allow-jit entitlement. glib falls back to the interpreter.
  cmake_build pcre2 "$s" -DPCRE2_BUILD_PCRE2_8=ON -DPCRE2_BUILD_PCRE2_16=OFF -DPCRE2_BUILD_PCRE2_32=OFF \
    -DPCRE2_SUPPORT_JIT=OFF -DPCRE2_BUILD_PCRE2GREP=OFF -DPCRE2_BUILD_TESTS=OFF \
    -DPCRE2_SUPPORT_LIBBZ2=OFF -DPCRE2_SUPPORT_LIBZ=OFF -DPCRE2_SUPPORT_LIBREADLINE=OFF \
    -DPCRE2_SUPPORT_LIBEDIT=OFF -DPCRE2_STATIC_PIC=ON
  license pcre2 "$s/LICENCE.md"
}

build_glib() {
  local s intl; s=$(src glib)
  # proxy-libintl (glib's gettext stub, LGPL) is glib's meson subproject; the
  # pinned, verified tree goes where glib's wrap expects it, so nothing is downloaded.
  cp -R "$(src proxy-libintl)" "$s/subprojects/proxy-libintl-$(pin_version proxy-libintl)"
  # The 26 SDKs' libSystem stubs export pipe2 without declaring it for older
  # deployment targets, so meson's link test finds it although it does not
  # exist on iOS 16 / macOS 12.
  perl -0pi -e "s/\n  'pipe2',//" "$s/meson.build"
  # _NSGetEnviron is private API on iOS (App Store rejection); glib only skips it
  # for the deprecated system = 'ios', so restrict it to macOS here.
  perl -0pi -e "s/if host_system == 'darwin'\n  functions \+= \['_NSGetEnviron'\]/if host_system == 'darwin' and subsystem == 'macos'\n  functions += ['_NSGetEnviron']/" "$s/meson.build"
  grep -B1 "functions += \['_NSGetEnviron'\]" "$s/meson.build" | grep "subsystem == 'macos'" >/dev/null \
    || die "glib: _NSGetEnviron patch did not apply"
  if grep -q "^  'pipe2',$" "$s/meson.build"; then die "glib: pipe2 patch did not apply"; fi
  meson_build glib "$s" -Dtests=false -Dinstalled_tests=false -Dnls=disabled -Dintrospection=disabled \
    -Dman-pages=disabled -Ddocumentation=false -Ddtrace=disabled -Dsystemtap=disabled -Dsysprof=disabled \
    -Dlibmount=disabled -Dselinux=disabled -Dxattr=false -Dlibelf=disabled -Dglib_debug=disabled \
    -Dforce_fallback_for=proxy-libintl
  license glib "$s/LICENSES/LGPL-2.1-or-later.txt"
  license proxy-libintl "$s/subprojects/proxy-libintl-$(pin_version proxy-libintl)/COPYING"
  # libintl is its own LGPL dylib (framework): separate build-info.
  intl=$(new_dylibs 'libintl*.dylib')
  [ -n "${intl// /}" ] || die "glib did not build proxy-libintl as a dylib"
  CLAIMED+=" $intl"
  (STEP_ARGS=("glib meson subproject" "-Ddefault_library=shared"); SCAN_LIBS="$intl" \
    finish proxy-libintl "$BUILD/glib" "$s/subprojects/proxy-libintl-$(pin_version proxy-libintl)")
}

build_expat() {
  local s; s=$(src expat)
  cmake_build expat "$s" -DEXPAT_BUILD_TOOLS=OFF -DEXPAT_BUILD_EXAMPLES=OFF -DEXPAT_BUILD_TESTS=OFF \
    -DEXPAT_BUILD_DOCS=OFF -DEXPAT_SHARED_LIBS=ON -DEXPAT_BUILD_FUZZERS=OFF
  license expat "$s/COPYING"
}

build_brotli() {
  local s; s=$(src brotli)
  cmake_build brotli "$s" -DBROTLI_DISABLE_TESTS=ON -DBROTLI_BUILD_TOOLS=OFF
  license brotli "$s/LICENSE"
}

build_highway() {
  local s; s=$(src highway)
  cmake_build highway "$s" -DHWY_ENABLE_TESTS=OFF -DHWY_ENABLE_EXAMPLES=OFF -DHWY_ENABLE_CONTRIB=OFF \
    -DHWY_ENABLE_INSTALL=ON -DHWY_FORCE_STATIC_LIBS=OFF
  license highway "$s/LICENSE" "$s/LICENSE-BSD3"
}

# --- audio / video codecs -----------------------------------------------------

build_opus() {
  local s; s=$(src opus)
  cmake_build opus "$s" -DOPUS_BUILD_PROGRAMS=OFF -DOPUS_BUILD_TESTING=OFF -DOPUS_BUILD_SHARED_LIBRARY=ON \
    -DOPUS_FORTIFY_SOURCE=ON -DOPUS_STACK_PROTECTOR=ON
  license opus "$s/COPYING"
}

build_libvpx() {
  local s target cflags extra=()
  s=$(src libvpx)
  # libvpx's own darwin targets add their SDK, -arch and min-version flags (it
  # rejects a second -target); the arm64 simulator has no libvpx target, so it
  # uses the portable C build with our flags. The dylib itself is linked below
  # with the slice's deployment target.
  cflags="$HARDEN_CFLAGS"
  local tc=""
  case $SLICE in
    ios-arm64) target=arm64-darwin-gcc ;;
    iossim-arm64) target=generic-gnu; tc=" $TFLAGS" ;;
    iossim-x86_64) target=x86_64-iphonesimulator-gcc ;;
    macos-arm64) target=arm64-darwin21-gcc; cflags="-mmacosx-version-min=$MACOS_MIN $HARDEN_CFLAGS" ;;
    macos-x86_64) target=x86_64-darwin21-gcc; cflags="-mmacosx-version-min=$MACOS_MIN $HARDEN_CFLAGS" ;;
  esac
  if [ "$ARCH" = x86_64 ]; then extra+=(--as=nasm); else extra+=(--disable-sve --disable-sve2); fi
  record_args --target="$target" --enable-pic --enable-vp8 --enable-vp9 --enable-vp9-highbitdepth --enable-multithread "${extra[@]}"
  (cd "$s" && run_logged libvpx env CC="$CC_BIN$tc" CXX="$CXX_BIN$tc" AR="$AR_BIN" LD="$CC_BIN$tc" \
    NASM="$NASM" PATH="$(dirname "$NASM"):$PATH" \
    ./configure --target="$target" --prefix="$PREFIX" --enable-static --disable-shared --enable-pic \
    --disable-examples --disable-tools --disable-docs --disable-unit-tests --disable-install-bins \
    --enable-vp8 --enable-vp9 --enable-vp9-highbitdepth --enable-multithread \
    --extra-cflags="$cflags" --extra-cxxflags="$cflags" "${extra[@]}")
  run_logged libvpx make -C "$s" -j "$JOBS"
  run_logged libvpx make -C "$s" install
  wrap_static libvpx "$PREFIX/lib/libvpx.a" libvpx.dylib "$(pin_version libvpx)"
  license libvpx "$s/LICENSE" "$s/PATENTS"
}

build_dav1d() {
  local s; s=$(src dav1d)
  meson_build dav1d "$s" -Denable_tools=false -Denable_examples=false -Denable_tests=false -Denable_docs=false
  license dav1d "$s/COPYING"
}

# --- subtitles / text ---------------------------------------------------------

build_freetype() {
  local s; s=$(src freetype)
  meson_build freetype "$s" -Dbrotli=disabled -Dbzip2=disabled -Dharfbuzz=disabled -Dpng=disabled \
    -Dzlib=system -Dtests=disabled
  license freetype "$s/LICENSE.TXT" "$s/docs/FTL.TXT"
}

build_fribidi() {
  local s; s=$(src fribidi)
  meson_build fribidi "$s" -Ddocs=false -Dbin=false -Dtests=false
  license fribidi "$s/COPYING"
}

build_harfbuzz() {
  local s; s=$(src harfbuzz)
  meson_build harfbuzz "$s" --auto-features=disabled -Dfreetype=enabled -Dcoretext=enabled \
    -Dtests=disabled -Ddocs=disabled -Dutilities=disabled -Dintrospection=disabled -Dbenchmark=disabled \
    -Dsubset=enabled
  license harfbuzz "$s/COPYING"
}

build_libass() {
  local s; s=$(src libass)
  meson_build libass "$s" -Dfontconfig=disabled -Ddirectwrite=disabled -Dcoretext=enabled \
    -Dlibunibreak=disabled -Dasm=enabled -Drequire-system-font-provider=true \
    -Dtest=disabled -Dcompare=disabled -Dprofile=disabled -Dfuzz=disabled -Dcheckasm=disabled
  license libass "$s/COPYING"
}

# --- images -------------------------------------------------------------------

build_lcms2() {
  local s; s=$(src lcms2)
  # fastfloat and threaded are GPL-3.0 plugins: never built.
  meson_build lcms2 "$s" -Dtests=disabled -Djpeg=disabled -Dtiff=disabled -Dutils=false \
    -Dfastfloat=false -Dthreaded=false
  license lcms2 "$s/LICENSE"
}

build_libjpeg-turbo() {
  local s; s=$(src libjpeg-turbo)
  cmake_build libjpeg-turbo "$s" -DENABLE_SHARED=ON -DENABLE_STATIC=OFF -DWITH_TURBOJPEG=ON \
    -DWITH_TOOLS=OFF -DWITH_TESTS=OFF -DWITH_JAVA=OFF
  license libjpeg-turbo "$s/LICENSE.md" "$s/README.ijg"
}

build_libspng() {
  local s; s=$(src libspng)
  meson_build libspng "$s" -Denable_opt=true -Dbuild_examples=false -Dbenchmarks=false -Dstatic_zlib=false
  license libspng "$s/LICENSE"
}

build_libwebp() {
  local s; s=$(src libwebp)
  cmake_build libwebp "$s" -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF \
    -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF -DWEBP_BUILD_WEBPINFO=OFF \
    -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF -DWEBP_BUILD_FUZZTEST=OFF -DWEBP_USE_THREAD=ON
  license libwebp "$s/COPYING" "$s/PATENTS"
}

build_libdeflate() {
  local s; s=$(src libdeflate)
  cmake_build libdeflate "$s" -DLIBDEFLATE_BUILD_STATIC_LIB=OFF -DLIBDEFLATE_BUILD_SHARED_LIB=ON \
    -DLIBDEFLATE_BUILD_GZIP=OFF -DLIBDEFLATE_BUILD_TESTS=OFF -DLIBDEFLATE_APPLE_FRAMEWORK=OFF
  license libdeflate "$s/COPYING"
}

build_zstd() {
  local s; s=$(src zstd)
  cmake_build zstd "$s/build/cmake" -DZSTD_BUILD_PROGRAMS=OFF -DZSTD_BUILD_TESTS=OFF -DZSTD_BUILD_STATIC=OFF \
    -DZSTD_BUILD_SHARED=ON -DZSTD_LEGACY_SUPPORT=OFF -DZSTD_MULTITHREAD_SUPPORT=ON
  license zstd "$s/LICENSE"
}

build_xz() {
  local s; s=$(src xz)
  cmake_build xz "$s" -DXZ_NLS=OFF -DXZ_DOC=OFF -DXZ_TOOL_XZDEC=OFF -DXZ_TOOL_LZMADEC=OFF \
    -DXZ_TOOL_LZMAINFO=OFF -DXZ_TOOL_XZ=OFF -DXZ_TOOL_SCRIPTS=OFF -DXZ_TOOL_SYMLINKS=OFF \
    -DXZ_TOOL_SYMLINKS_LZMA=OFF -DXZ_DOXYGEN=OFF
  license xz "$s/COPYING" "$s/COPYING.0BSD"
}

build_libtiff() {
  local s; s=$(src libtiff)
  cmake_build libtiff "$s" -Dtiff-tools=OFF -Dtiff-tests=OFF -Dtiff-contrib=OFF -Dtiff-docs=OFF \
    -Dtiff-deprecated=OFF -Dcxx=OFF -Djbig=OFF -Dlerc=OFF -Dlzma=ON -Dzstd=ON -Dlibdeflate=ON \
    -Dwebp=ON -Djpeg=ON -Dzlib=ON -Dpixarlog=ON -Dold-jpeg=OFF -Djpeg12=OFF -Dtiff-framework=OFF
  license libtiff "$s/LICENSE.md"
}

build_imath() {
  local s; s=$(src imath)
  cmake_build imath "$s" -DIMATH_LIB_SUFFIX= -DIMATH_INSTALL_PKG_CONFIG=ON -DPYTHON=OFF -DBUILD_WEBSITE=OFF
  license imath "$s/LICENSE.md"
}

build_openexr() {
  local s; s=$(src openexr)
  # libdeflate and zstd are ours; OpenJPH (HTJ2K) is vendored in OpenEXR's own
  # tarball (external/OpenJPH) and compiled into OpenEXRCore. Never a download.
  cmake_build openexr "$s" -DOPENEXR_LIB_SUFFIX= -DOPENEXR_BUILD_TOOLS=OFF -DOPENEXR_INSTALL_TOOLS=OFF \
    -DOPENEXR_BUILD_EXAMPLES=OFF -DOPENEXR_BUILD_PYTHON=OFF -DOPENEXR_TEST_LIBRARIES=OFF \
    -DOPENEXR_TEST_TOOLS=OFF -DOPENEXR_TEST_PYTHON=OFF -DOPENEXR_INSTALL_PKG_CONFIG=ON \
    -DOPENEXR_FORCE_INTERNAL_IMATH=OFF -DOPENEXR_FORCE_INTERNAL_DEFLATE=OFF -DOPENEXR_FORCE_INTERNAL_ZSTD=OFF \
    -DOPENEXR_FORCE_INTERNAL_OPENJPH=ON -DOPENEXR_BUILD_OSS_FUZZ=OFF -DFETCHCONTENT_FULLY_DISCONNECTED=ON
  license openexr "$s/LICENSE.md"
}

build_libexif() {
  local s; s=$(src libexif)
  autotools_build libexif "$s" --disable-docs --disable-nls --without-libiconv-prefix
  license libexif "$s/COPYING"
}

build_libjxl() {
  local s; s=$(src libjxl)
  cmake_build libjxl "$s" -DJPEGXL_ENABLE_TOOLS=OFF -DJPEGXL_ENABLE_DOXYGEN=OFF -DJPEGXL_ENABLE_MANPAGES=OFF \
    -DJPEGXL_ENABLE_BENCHMARK=OFF -DJPEGXL_ENABLE_EXAMPLES=OFF -DJPEGXL_ENABLE_JNI=OFF \
    -DJPEGXL_ENABLE_SJPEG=OFF -DJPEGXL_ENABLE_OPENEXR=OFF -DJPEGXL_ENABLE_SKCMS=OFF \
    -DJPEGXL_ENABLE_JPEGLI=OFF -DJPEGXL_ENABLE_PLUGINS=OFF -DJPEGXL_ENABLE_DEVTOOLS=OFF \
    -DJPEGXL_ENABLE_FUZZERS=OFF -DJPEGXL_BUNDLE_LIBPNG=OFF -DJPEGXL_FORCE_SYSTEM_BROTLI=ON \
    -DJPEGXL_FORCE_SYSTEM_HWY=ON -DJPEGXL_FORCE_SYSTEM_LCMS2=ON -DJPEGXL_ENABLE_SIZELESS_VECTORS=OFF \
    -DJPEGXL_STATIC=OFF -DJPEGXL_ENABLE_TRANSCODE_JPEG=ON -DJPEGXL_ENABLE_BOXES=ON
  license libjxl "$s/LICENSE" "$s/PATENTS"
}

build_libavif() {
  local s; s=$(src libavif)
  cmake_build libavif "$s" -DAVIF_CODEC_DAV1D=SYSTEM -DAVIF_CODEC_AOM=OFF -DAVIF_CODEC_RAV1E=OFF \
    -DAVIF_CODEC_SVT=OFF -DAVIF_CODEC_LIBGAV1=OFF -DAVIF_LIBYUV=OFF -DAVIF_LIBSHARPYUV=OFF \
    -DAVIF_LIBXML2=OFF -DAVIF_JPEG=OFF -DAVIF_ZLIBPNG=OFF -DAVIF_BUILD_APPS=OFF -DAVIF_BUILD_TESTS=OFF \
    -DAVIF_BUILD_EXAMPLES=OFF
  license libavif "$s/LICENSE"
}

build_libraw() {
  local s; s=$(src libraw)
  autotools_build libraw "$s" --disable-examples --disable-openmp --disable-jasper --enable-lcms --enable-jpeg \
    --enable-zlib
  license libraw "$s/LICENSE.CDDL" "$s/COPYRIGHT"
}

# --- text, audio analysis -------------------------------------------------------

build_uchardet() {
  local s; s=$(src uchardet)
  cmake_build uchardet "$s" -DBUILD_BINARY=OFF -DBUILD_STATIC=OFF
  license uchardet "$s/COPYING"
}

build_libebur128() {
  local s; s=$(src libebur128)
  cmake_build libebur128 "$s" -DBUILD_STATIC_LIBS=OFF -DENABLE_INTERNAL_QUEUE_H=ON
  license libebur128 "$s/COPYING"
}

build_chromaprint() {
  local s; s=$(src chromaprint)
  # FFT from Accelerate's vDSP: no FFmpeg/FFTW dependency in the library.
  cmake_build chromaprint "$s" -DFFT_LIB=vdsp -DBUILD_TOOLS=OFF -DBUILD_TESTS=OFF
  license chromaprint "$s/LICENSE.md"
}

build_whisper.cpp() {
  local s; s=$(src whisper.cpp)
  cmake_build whisper.cpp "$s" -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_SERVER=OFF \
    -DWHISPER_CURL=OFF -DWHISPER_SDL2=OFF -DWHISPER_COREML=OFF -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_BLAS=ON -DGGML_BLAS_VENDOR=Apple \
    -DGGML_ACCELERATE=ON -DGGML_CCACHE=OFF -DGGML_BUILD_TESTS=OFF -DGGML_BUILD_EXAMPLES=OFF
  license whisper.cpp "$s/LICENSE"
}

# --- media sources --------------------------------------------------------------

build_libudfread() {
  local s; s=$(src libudfread)
  meson_build libudfread "$s" -Denable_examples=false
  license libudfread "$s/COPYING"
}

build_libbluray() {
  local s; s=$(src libbluray)
  if [ "$OS" = ios ]; then
    # DiskArbitration (disc mount lookup) is macOS-only: iOS uses the generic stub.
    cp "$s/src/file/mount.c" "$s/src/file/mount_darwin.c"
    perl -0pi -e "s/modules: \['CoreFoundation', 'DiskArbitration'\]/modules: ['CoreFoundation']/" "$s/meson.build"
    if grep -q DiskArbitration "$s/meson.build"; then die "libbluray: DiskArbitration patch did not apply"; fi
  fi
  # Unencrypted BDMV only: no libaacs/libbdplus are shipped, no BD-J (Java).
  meson_build libbluray "$s" -Denable_docs=false -Denable_tools=false -Denable_devtools=false \
    -Denable_examples=false -Dbdj_jar=disabled -Dembed_udfread=false -Dfontconfig=disabled \
    -Dfreetype=disabled -Dlibxml2=disabled
  license libbluray "$s/COPYING"
}

build_libopenmpt() {
  local s; s=$(src libopenmpt)
  autotools_build libopenmpt "$s" --disable-openmpt123 --disable-examples --disable-tests \
    --disable-doxygen-doc --without-mpg123 --without-ogg --without-vorbis --without-vorbisfile \
    --without-portaudio --without-portaudiocpp --without-pulseaudio --without-sndfile --without-flac
  license libopenmpt "$s/LICENSE"
}

build_libsmb2() {
  local s; s=$(src libsmb2)
  # NTLM/SMB3 signing and encryption use libsmb2's bundled primitives (no
  # OpenSSL); listed in the encryption inventory (docs/07 rule 12).
  cmake_build libsmb2 "$s" -DENABLE_EXAMPLES=OFF -DENABLE_LIBKRB5=OFF -DENABLE_GSSAPI=OFF
  license libsmb2 "$s/COPYING" "$s/LICENCE-LGPL-2.1.txt"
}

build_libnfs() {
  local s; s=$(src libnfs)
  cmake_build libnfs "$s" -DENABLE_EXAMPLES=OFF -DENABLE_TESTS=OFF -DENABLE_UTILS=OFF \
    -DENABLE_DOCUMENTATION=OFF -DENABLE_TLS=OFF
  license libnfs "$s/COPYING" "$s/LICENCE-LGPL-2.1.txt"
}

build_curl() {
  local s; s=$(src curl)
  # curl >= 8.15 has no SecureTransport backend; HTTPS goes through the OS stack
  # (URLSession / Network.framework) via the app's stream callbacks, so curl is
  # built without any TLS library (docs/05 4.1, docs/07 rule 12).
  cmake_build curl "$s" -DCURL_ENABLE_SSL=OFF -DCURL_USE_OPENSSL=OFF -DCURL_USE_LIBSSH2=OFF \
    -DCURL_USE_LIBSSH=OFF -DCURL_USE_LIBPSL=OFF -DCURL_BROTLI=ON -DCURL_ZSTD=ON -DUSE_NGHTTP2=OFF \
    -DUSE_LIBIDN2=OFF -DCURL_DISABLE_LDAP=ON -DCURL_DISABLE_LDAPS=ON -DBUILD_CURL_EXE=OFF \
    -DBUILD_LIBCURL_DOCS=OFF -DBUILD_MISC_DOCS=OFF -DENABLE_CURL_MANUAL=OFF -DCURL_ZLIB=ON \
    -DUSE_APPLE_IDN=ON -DBUILD_EXAMPLES=OFF -DCURL_CA_PATH=none -DCURL_CA_BUNDLE=none
  license curl "$s/COPYING"
}

build_libarchive() {
  local s; s=$(src libarchive)
  # Digests via CommonCrypto (OS); no OpenSSL/mbedTLS/Nettle.
  cmake_build libarchive "$s" -DENABLE_OPENSSL=OFF -DENABLE_MBEDTLS=OFF -DENABLE_NETTLE=OFF \
    -DENABLE_LIBB2=OFF -DENABLE_LZ4=OFF -DENABLE_LZO=OFF -DENABLE_LZMA=ON -DENABLE_ZSTD=ON \
    -DENABLE_BZip2=ON -DENABLE_ZLIB=ON -DENABLE_LIBXML2=OFF -DENABLE_EXPAT=OFF -DENABLE_ICONV=ON \
    -DENABLE_ACL=OFF -DENABLE_XATTR=OFF -DENABLE_TAR=OFF -DENABLE_CPIO=OFF -DENABLE_CAT=OFF \
    -DENABLE_UNZIP=OFF -DENABLE_TEST=OFF -DENABLE_WERROR=OFF -DENABLE_INSTALL=ON
  rm -f "$PREFIX/lib/libarchive.a"
  license libarchive "$s/COPYING"
}

# --- libvips ---------------------------------------------------------------------

build_libvips() {
  local s; s=$(src libvips)
  read_flags "$ROOT/flags/vips.flags"; local common=("${FLAGS[@]}")
  read_flags "$APPLE/flags/vips.apple.flags"
  merge_flags "${common[@]}" -- "${FLAGS[@]}"
  meson_build libvips "$s" "${MERGED[@]}"
  license libvips "$s/LICENSE"
}

# --- GPU: Vulkan on Metal ----------------------------------------------------------

# The extracted tree stays in $SLICE_DIR/src for MoltenVK and libplacebo.
vk_headers_dir() { printf '%s\n' "$SLICE_DIR/src/vulkan-headers"; }

build_vulkan-headers() {
  local s; s=$(src vulkan-headers)
  cmake_build vulkan-headers "$s" -DVULKAN_HEADERS_ENABLE_TESTS=OFF -DVULKAN_HEADERS_ENABLE_MODULE=OFF
  license vulkan-headers "$s/LICENSE.md"
  header_only vulkan-headers "libMoltenVK, libplacebo, libmpv, libavutil (include/vulkan)"
}

build_moltenvk() {
  local s sc cr ver; s=$(src moltenvk); sc=$(src spirv-cross); cr=$(src cereal)
  [ "$(cat "$s/ExternalRevisions/cereal_repo_revision")" = "$(pin_commit cereal)" ] \
    || die "cereal pin differs from MoltenVK's ExternalRevisions"
  if [ "$OS" = ios ]; then
    # MoltenVK's CMake build links the macOS frameworks unconditionally; on iOS
    # the platform UI framework is UIKit, IOKit is not used and CoreGraphics
    # (which AppKit brings in on macOS) is linked directly.
    perl -0pi -e 's/find_library\(APPKIT_LIBRARY AppKit REQUIRED\)/find_library(APPKIT_LIBRARY UIKit REQUIRED)/; s/find_library\(IOKIT_LIBRARY IOKit REQUIRED\)/find_library(IOKIT_LIBRARY CoreGraphics REQUIRED)/' "$s/Common/CMakeLists.txt"
    if grep -q -e AppKit -e 'IOKit REQUIRED' "$s/Common/CMakeLists.txt"; then die "MoltenVK: iOS framework patch did not apply"; fi
  fi
  ver=$(sed -n 's/^#define VK_HEADER_VERSION \([0-9]*\).*/\1/p' "$PREFIX/include/vulkan/vulkan_core.h")
  # Vulkan-Headers, SPIRV-Cross and cereal are the verified versions.json pins
  # (CPM uses them instead of cloning anything). SPIRV-Tools only adds debug
  # disassembly: left out.
  cmake_build moltenvk "$s" -DCPM_SOURCE_CACHE="$CACHE/cpm" -DCPM_Vulkan-Headers_SOURCE="$(vk_headers_dir)" \
    -DCPM_SPIRV-Cross_SOURCE="$sc" -DCPM_cereal_SOURCE="$cr" -DMVK_EXCLUDE_SPIRV_TOOLS=ON \
    -DMVK_USE_METAL_PRIVATE_API=OFF -DMVK_BUILD_SHADER_CONVERTER_TOOL=OFF -DMVK_CONFIG_LOG_LEVEL=warn \
    -DMOLTEN_VK_WITH_CCACHE=OFF
  scan_into spirv-cross "$sc" "$BUILD/moltenvk" 'libMoltenVK*.dylib'
  scan_into cereal "$cr" "$BUILD/moltenvk" 'libMoltenVK*.dylib'
  license spirv-cross "$sc/LICENSE"
  license cereal "$cr/LICENSE"
  cat >"$PREFIX/lib/pkgconfig/vulkan.pc" <<EOF
prefix=$PREFIX
includedir=\${prefix}/include
libdir=\${prefix}/lib

Name: vulkan
Description: Vulkan via MoltenVK $(pin_version moltenvk) (Metal)
Version: 1.4.$ver
Libs: -L\${libdir} -lMoltenVK
Cflags: -I\${includedir}
EOF
  license moltenvk "$s/LICENSE"
}

# SPIR-V compiler for libplacebo's Vulkan backend: glslang as a static library
# without its SPIRV-Tools optimiser and HLSL front end (ADR-020, as on Android).
# It is compiled into libplacebo; no glslang framework ships.
build_glslang() {
  local s; s=$(src glslang)
  cmake_build glslang "$s" -DBUILD_SHARED_LIBS=OFF -DENABLE_OPT=OFF -DENABLE_HLSL=OFF \
    -DENABLE_GLSLANG_BINARIES=OFF -DGLSLANG_TESTS=OFF -DENABLE_CTEST=OFF -DGLSLANG_ENABLE_INSTALL=ON \
    -DBUILD_EXTERNAL=OFF -DENABLE_SPVREMAPPER=OFF
  license glslang "$s/LICENSE.txt"
  (SCAN_LIBS="" finish glslang "$BUILD/glslang" "$s" placebo.framework)
}

build_libplacebo() {
  local s ff gl; s=$(src libplacebo)
  # Submodules are not in the release tarball: fast_float (headers), glad (GL
  # loader generator) and Vulkan-Headers come from their own pins; jinja2 is a
  # build-time tool (pip).
  ff=$(src fast_float); gl=$(src glad)
  rm -rf "$s/3rdparty/fast_float" "$s/3rdparty/glad" "$s/3rdparty/Vulkan-Headers"
  mv "$ff" "$s/3rdparty/fast_float"
  mv "$gl" "$s/3rdparty/glad"
  cp -R "$(vk_headers_dir)" "$s/3rdparty/Vulkan-Headers"
  read_flags "$ROOT/flags/libplacebo.flags"; local common=("${FLAGS[@]}")
  read_flags "$APPLE/flags/libplacebo.apple.flags"
  merge_flags "${common[@]}" -- "${FLAGS[@]}"
  # glslang 16 keeps everything in libglslang.a, which libplacebo's probe does
  # not add itself; the command-line link args replace the cross file's.
  local la="$HARDEN_LDFLAGS -L$PREFIX/lib -lglslang -lglslang-default-resource-limits -lc++"
  meson_build libplacebo "$s" "${MERGED[@]}" -Dvulkan-sdk="$PREFIX" -Dprefer_static=true \
    "-Dc_link_args=$la" "-Dcpp_link_args=$la"
  license libplacebo "$s/LICENSE"
  license fast_float "$s/3rdparty/fast_float/LICENSE-MIT" "$s/3rdparty/fast_float/LICENSE-APACHE" "$s/3rdparty/fast_float/LICENSE-BOOST"
  license glad "$s/3rdparty/glad/LICENSE"
  header_only fast_float libplacebo
  header_only glad "libplacebo (generated OpenGL loader)"
}

# --- FFmpeg and mpv ------------------------------------------------------------------

build_ffmpeg() {
  local s arch b; s=$(src ffmpeg)
  read_flags "$ROOT/flags/ffmpeg.common.flags"
  # A --disable-X for a component upstream has removed (FFmpeg 8 dropped
  # libpostproc, so --disable-postproc is unknown) is a no-op: skip it, loudly.
  local help common=() f
  help=$("$s/configure" --help)
  for f in "${FLAGS[@]}"; do
    local opt=${f%%=*}
    if [[ $opt == --disable-* ]] && ! grep -qE -- "--(en|dis)able-${opt#--disable-}([ =]|$)" <<<"$help"; then
      echo "ffmpeg: skipping $f (not an option of FFmpeg $(pin_version ffmpeg))" >>"$WORK/notes.txt"
      continue
    fi
    common+=("$f")
  done
  read_flags "$ROOT/flags/ffmpeg.apple.flags"; local apple=("${FLAGS[@]}")
  record_args --target-os=darwin --optflags="$OPT_LEVEL" "${common[@]}" "${apple[@]}"
  case $ARCH in arm64) arch=aarch64 ;; x86_64) arch=x86_64 ;; esac
  b="$BUILD/ffmpeg"
  rm -rf "$b"; mkdir -p "$b"
  (cd "$b" && run_logged ffmpeg env -u CC -u CFLAGS -u LDFLAGS "$s/configure" --prefix="$PREFIX" \
    --enable-cross-compile --target-os=darwin --arch="$arch" \
    --cc="$CC_BIN" --cxx="$CXX_BIN" --objcc="$CC_BIN" --ar="$AR_BIN" --ranlib="$RANLIB_BIN" \
    --strip="$STRIP_BIN" --nm="$(xcrun --sdk "$SDK" -f nm)" --x86asmexe="$NASM" \
    --sysroot="$SYSROOT" --pkg-config="$PKGCONF" \
    --optflags="$OPT_LEVEL" \
    --extra-cflags="-target $TRIPLE -I$PREFIX/include $HARDEN_CFLAGS" \
    --extra-objcflags="-target $TRIPLE $HARDEN_CFLAGS" \
    --extra-ldflags="-target $TRIPLE -L$PREFIX/lib $HARDEN_LDFLAGS" \
    --install-name-dir="$PREFIX/lib" \
    "${common[@]}" "${apple[@]}")
  # --disable-everything makes every component explicit: a misspelt name must
  # not drop a format silently (same guard as android/build.sh).
  if grep -E "did not match anything|Unknown option" "$LOGS/$SLICE-ffmpeg.log" >&2; then
    die "FFmpeg configure: fix the component names above (flags/ffmpeg.*.flags)"
  fi
  # --disable-autodetect makes configure drop requested features silently; fail instead.
  local cfg="$b/ffbuild/config.mak"
  for f in VIDEOTOOLBOX AUDIOTOOLBOX LIBDAV1D LIBVPX LIBOPUS LIBOPENMPT LIBWEBP LIBJXL VULKAN ZLIB BZLIB ICONV LIBXML2 \
    H264_VIDEOTOOLBOX_ENCODER HEVC_VIDEOTOOLBOX_ENCODER AAC_AT_ENCODER AAC_AT_DECODER H264_VIDEOTOOLBOX_HWACCEL \
    HEVC_VIDEOTOOLBOX_HWACCEL PGSSUB_DECODER LIBOPENMPT_DEMUXER HLS_MUXER; do
    require_grep "$cfg" "^CONFIG_$f=yes" "FFmpeg configure dropped $f"
  done
  # TLS from the OS only: SecureTransport (Security.framework) on every slice.
  require_grep "$cfg" "^CONFIG_SECURETRANSPORT=yes" "FFmpeg configure dropped SecureTransport"
  echo "ffmpeg ($SLICE): TLS via SecureTransport" >>"$WORK/notes.txt"
  for f in GPL NONFREE VERSION3 OPENSSL GNUTLS MBEDTLS LIBTLS POSTPROC; do
    if grep -q "^CONFIG_$f=yes" "$cfg"; then die "FFmpeg enabled $f on $SLICE"; fi
  done
  run_logged ffmpeg make -C "$b" -j "$JOBS"
  run_logged ffmpeg make -C "$b" install
  license ffmpeg "$s/COPYING.LGPLv2.1" "$s/LICENSE.md"
}

build_mpv() {
  local s; s=$(src mpv)
  read_flags "$ROOT/flags/mpv.flags"; local common=("${FLAGS[@]}")
  read_flags "$APPLE/flags/mpv.apple.flags"; local apple=("${FLAGS[@]}")
  read_flags "$APPLE/flags/mpv.$OS.flags"; local os=("${FLAGS[@]}")
  merge_flags "${common[@]}" -- "${apple[@]}" "${os[@]}"
  local extra=()
  [ "$OS" = macos ] && extra+=("-Dswift-flags=-target $TRIPLE")
  # mpv adds "-isysroot <SDK>" to every link from TOOLS/macos-sdk-version.py,
  # which defaults to the macOS SDK; point it at this slice's SDK.
  MACOS_SDK=$SYSROOT MACOS_SDK_VERSION=$(xcrun --sdk "$SDK" --show-sdk-version) \
    meson_build mpv "$s" "${MERGED[@]}" "${extra[@]}"
  local cfg="$BUILD/mpv/config.h"
  require_grep "$cfg" "#define HAVE_GPL 0" "mpv must be the LGPL build"
  for f in VULKAN VIDEOTOOLBOX_PL; do
    require_grep "$cfg" "#define HAVE_$f 1" "mpv configure dropped $f"
  done
  license mpv "$s/LICENSE.LGPL" "$s/Copyright"
}
