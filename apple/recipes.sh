# shellcheck shell=bash
# One build_<name> function per library, run once per slice in RECIPES order.
# Every library is built shared so it can become its own .framework.

RECIPES="libffi pcre2 glib expat brotli highway libogg opus flac libvpx dav1d vvdec
freetype fribidi harfbuzz libass lcms2 libjpeg-turbo libspng libwebp libtiff imath openexr
cgif libexif libjxl libavif libraw uchardet libebur128 libbluray libopenmpt libsmb2 libnfs
curl libarchive chromaprint whisper.cpp libvips vulkan-headers moltenvk shaderc libplacebo
ffmpeg mpv"

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
  local s wrapdir; s=$(src glib)
  # proxy-libintl (glib's gettext stub, LGPL) comes from glib's own wrap; place the
  # pinned, verified tarball in meson's package cache so nothing is downloaded.
  wrapdir="$s/subprojects/packagecache"
  mkdir -p "$wrapdir"
  cp "$(fetch proxy-libintl)" "$wrapdir/proxy-libintl-$(pin_version proxy-libintl).tar.gz"
  # The 26 SDKs' libSystem stubs export pipe2 without declaring it for older
  # deployment targets, so meson's link test finds it although it does not
  # exist on iOS 16 / macOS 12.
  perl -0pi -e "s/\n  'pipe2',//" "$s/meson.build"
  # _NSGetEnviron is private API on iOS (App Store rejection); glib only skips it
  # for the deprecated system = 'ios', so restrict it to macOS here.
  perl -0pi -e "s/if host_system == 'darwin'\n  functions \+= \['_NSGetEnviron'\]/if host_system == 'darwin' and subsystem == 'macos'\n  functions += ['_NSGetEnviron']/" "$s/meson.build"
  grep -B1 "functions += \['_NSGetEnviron'\]" "$s/meson.build" | grep -q "subsystem == 'macos'" \
    || die "glib: _NSGetEnviron patch did not apply"
  if grep -q "^  'pipe2',$" "$s/meson.build"; then die "glib: pipe2 patch did not apply"; fi
  meson_build glib "$s" -Dtests=false -Dinstalled_tests=false -Dnls=disabled -Dintrospection=disabled \
    -Dman-pages=disabled -Ddocumentation=false -Ddtrace=disabled -Dsystemtap=disabled -Dsysprof=disabled \
    -Dlibmount=disabled -Dselinux=disabled -Dxattr=false -Dlibelf=disabled -Dglib_debug=disabled \
    -Dforce_fallback_for=proxy-libintl
  license glib "$s/LICENSES/LGPL-2.1-or-later.txt"
  license proxy-libintl "$s/subprojects/proxy-libintl-$(pin_version proxy-libintl)/COPYING"
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

build_libogg() {
  local s; s=$(src libogg)
  cmake_build libogg "$s" -DINSTALL_DOCS=OFF
  license libogg "$s/COPYING"
}

build_opus() {
  local s; s=$(src opus)
  cmake_build opus "$s" -DOPUS_BUILD_PROGRAMS=OFF -DOPUS_BUILD_TESTING=OFF -DOPUS_BUILD_SHARED_LIBRARY=ON \
    -DOPUS_FORTIFY_SOURCE=ON -DOPUS_STACK_PROTECTOR=ON
  license opus "$s/COPYING"
}

build_flac() {
  local s; s=$(src flac)
  cmake_build flac "$s" -DBUILD_PROGRAMS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_DOCS=OFF -DINSTALL_MANPAGES=OFF \
    -DBUILD_CXXLIBS=OFF -DWITH_OGG=ON -DWITH_STACK_PROTECTOR=ON -DWITH_FORTIFY_SOURCE=ON
  license flac "$s/COPYING.Xiph"
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

build_vvdec() {
  local s x86=ON arm=OFF; s=$(src vvdec)
  # vvdec's x86 kernels also build on arm64 through its bundled SIMDe; its
  # native NEON kernels exist only for arm64.
  if [ "$ARCH" = arm64 ]; then arm=ON; fi
  cmake_build vvdec "$s" -DVVDEC_ENABLE_LINK_TIME_OPT=OFF -DVVDEC_INSTALL_VVDECAPP=OFF \
    -DVVDEC_ENABLE_X86_SIMD="$x86" -DVVDEC_ENABLE_ARM_SIMD="$arm" -DVVDEC_ENABLE_WERROR=OFF
  license vvdec "$s/LICENSE.txt"
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

build_libtiff() {
  local s; s=$(src libtiff)
  cmake_build libtiff "$s" -Dtiff-tools=OFF -Dtiff-tests=OFF -Dtiff-contrib=OFF -Dtiff-docs=OFF \
    -Dtiff-deprecated=OFF -Dcxx=OFF -Djbig=OFF -Dlerc=OFF -Dlzma=OFF -Dzstd=OFF -Dlibdeflate=OFF \
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
  # Uses its vendored libdeflate, zstd and OpenJPH (external/), never a download.
  cmake_build openexr "$s" -DOPENEXR_LIB_SUFFIX= -DOPENEXR_BUILD_TOOLS=OFF -DOPENEXR_INSTALL_TOOLS=OFF \
    -DOPENEXR_BUILD_EXAMPLES=OFF -DOPENEXR_BUILD_PYTHON=OFF -DOPENEXR_TEST_LIBRARIES=OFF \
    -DOPENEXR_TEST_TOOLS=OFF -DOPENEXR_TEST_PYTHON=OFF -DOPENEXR_INSTALL_PKG_CONFIG=ON \
    -DOPENEXR_FORCE_INTERNAL_IMATH=OFF -DOPENEXR_FORCE_INTERNAL_DEFLATE=ON -DOPENEXR_FORCE_INTERNAL_ZSTD=ON \
    -DOPENEXR_FORCE_INTERNAL_OPENJPH=ON -DOPENEXR_BUILD_OSS_FUZZ=OFF -DFETCHCONTENT_FULLY_DISCONNECTED=ON
  license openexr "$s/LICENSE.md"
}

build_cgif() {
  local s; s=$(src cgif)
  meson_build cgif "$s" -Dexamples=false -Dtests=false
  license cgif "$s/LICENSE"
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

build_libbluray() {
  local s; s=$(src libbluray)
  if [ "$OS" = ios ]; then
    # DiskArbitration (disc mount lookup) is macOS-only: iOS uses the generic stub.
    cp "$s/src/file/mount.c" "$s/src/file/mount_darwin.c"
    sed -i '' 's/ -framework DiskArbitration//' "$s/configure"
  fi
  # Unencrypted BDMV only: no libaacs/libbdplus, no BD-J (Java).
  autotools_build libbluray "$s" --disable-bdjava-jar --disable-examples --disable-doxygen-doc \
    --without-libxml2 --without-freetype --without-fontconfig
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
    -DCURL_USE_LIBSSH=OFF -DCURL_USE_LIBPSL=OFF -DCURL_BROTLI=OFF -DCURL_ZSTD=OFF -DUSE_NGHTTP2=OFF \
    -DUSE_LIBIDN2=OFF -DCURL_DISABLE_LDAP=ON -DCURL_DISABLE_LDAPS=ON -DBUILD_CURL_EXE=OFF \
    -DBUILD_LIBCURL_DOCS=OFF -DBUILD_MISC_DOCS=OFF -DENABLE_CURL_MANUAL=OFF -DCURL_ZLIB=ON \
    -DUSE_APPLE_IDN=ON -DBUILD_EXAMPLES=OFF -DCURL_CA_PATH=none -DCURL_CA_BUNDLE=none
  license curl "$s/COPYING"
}

build_libarchive() {
  local s; s=$(src libarchive)
  # Digests via CommonCrypto (OS); no OpenSSL/mbedTLS/Nettle.
  cmake_build libarchive "$s" -DENABLE_OPENSSL=OFF -DENABLE_MBEDTLS=OFF -DENABLE_NETTLE=OFF \
    -DENABLE_LIBB2=OFF -DENABLE_LZ4=OFF -DENABLE_LZO=OFF -DENABLE_LZMA=OFF -DENABLE_ZSTD=OFF \
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
  meson_build libvips "$s" "${common[@]}" "${FLAGS[@]}"
  license libvips "$s/LICENSE"
}

# --- GPU: Vulkan on Metal ----------------------------------------------------------

# The extracted tree stays in $SLICE_DIR/src for MoltenVK and libplacebo.
vk_headers_dir() { printf '%s\n' "$SLICE_DIR/src/vulkan-headers"; }

build_vulkan-headers() {
  local s; s=$(src vulkan-headers)
  cmake_build vulkan-headers "$s" -DVULKAN_HEADERS_ENABLE_TESTS=OFF -DVULKAN_HEADERS_ENABLE_MODULE=OFF
  license vulkan-headers "$s/LICENSE.md"
}

build_moltenvk() {
  local s ver; s=$(src moltenvk)
  ver=$(sed -n 's/^#define VK_HEADER_VERSION \([0-9]*\).*/\1/p' "$PREFIX/include/vulkan/vulkan_core.h")
  [ "$(cat "$s/ExternalRevisions/Vulkan-Headers_repo_revision")" = "$(pin_version vulkan-headers)" ] \
    || die "vulkan-headers pin differs from MoltenVK's ExternalRevisions"
  # SPIRV-Cross/Tools/Headers, Volk and cereal are fetched by CPM at the git
  # commits in MoltenVK's ExternalRevisions; Vulkan-Headers is our verified copy.
  cmake_build moltenvk "$s" -DCPM_SOURCE_CACHE="$CACHE/cpm" -DCPM_Vulkan-Headers_SOURCE="$(vk_headers_dir)" \
    -DMVK_USE_METAL_PRIVATE_API=OFF -DMVK_BUILD_SHADER_CONVERTER_TOOL=OFF -DMVK_CONFIG_LOG_LEVEL=warn \
    -DMOLTEN_VK_WITH_CCACHE=OFF
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
  local cpm d
  for d in "$CACHE"/cpm/*/; do
    for cpm in "$d"*/LICENSE* "$d"*/LICENSE.txt; do
      if [ -f "$cpm" ]; then
        license "moltenvk-$(basename "$d" | tr '[:upper:]' '[:lower:]')" "$cpm"
        break
      fi
    done
  done
}

build_shaderc() {
  local s g t h; s=$(src shaderc)
  g=$(src glslang); t=$(src spirv-tools); h=$(src spirv-headers)
  # Commits must match shaderc's DEPS so the sources are the ones shaderc tested.
  grep -q "'glslang_revision': '$(pin_version glslang)'" "$s/DEPS" || die "glslang pin differs from shaderc DEPS"
  grep -q "'spirv_tools_revision': '$(pin_version spirv-tools)'" "$s/DEPS" || die "spirv-tools pin differs from shaderc DEPS"
  grep -q "'spirv_headers_revision': '$(pin_version spirv-headers)'" "$s/DEPS" || die "spirv-headers pin differs from shaderc DEPS"
  rm -rf "$s/third_party/glslang" "$s/third_party/spirv-tools" "$s/third_party/spirv-headers"
  mv "$g" "$s/third_party/glslang"
  mv "$t" "$s/third_party/spirv-tools"
  mv "$h" "$s/third_party/spirv-headers"
  cmake_build shaderc "$s" -DSHADERC_SKIP_TESTS=ON -DSHADERC_SKIP_EXAMPLES=ON -DSHADERC_SKIP_EXECUTABLES=ON \
    -DSHADERC_SKIP_COPYRIGHT_CHECK=ON -DSHADERC_ENABLE_WERROR_COMPILE=OFF -DSPIRV_WERROR=OFF \
    -DSPIRV_SKIP_TESTS=ON -DSPIRV_SKIP_EXECUTABLES=ON -DENABLE_GLSLANG_BINARIES=OFF -DGLSLANG_TESTS=OFF \
    -DENABLE_HLSL=ON -DSKIP_GLSLANG_INSTALL=ON -DSKIP_SPIRV_TOOLS_INSTALL=ON -DSPIRV_HEADERS_SKIP_INSTALL=ON \
    -DBUILD_SHARED_LIBS=OFF -DSHADERC_ENABLE_SHARED_CRT=OFF
  # shaderc_shared is the self-contained dylib (glslang + SPIRV-Tools inside);
  # drop the static archives and point shaderc.pc at it.
  rm -f "$PREFIX"/lib/libshaderc.a "$PREFIX"/lib/libshaderc_combined.a "$PREFIX"/lib/libshaderc_util.a
  printf 'prefix=%s\nlibdir=${prefix}/lib\nincludedir=${prefix}/include\n\nName: shaderc\nDescription: shaderc (shared)\nVersion: %s\nLibs: -L${libdir} -lshaderc_shared\nCflags: -I${includedir}\n' \
    "$PREFIX" "$(pin_version shaderc)" >"$PREFIX/lib/pkgconfig/shaderc.pc"
  license shaderc "$s/LICENSE"
  license glslang "$s/third_party/glslang/LICENSE.txt"
  license spirv-tools "$s/third_party/spirv-tools/LICENSE"
  license spirv-headers "$s/third_party/spirv-headers/LICENSE"
}

build_libplacebo() {
  local s ff; s=$(src libplacebo)
  # Submodules are not in the release tarball: fast_float (headers) and
  # Vulkan-Headers come from their own pins; jinja2 is a build-time tool (pip).
  ff=$(src fast_float)
  rm -rf "$s/3rdparty/fast_float" "$s/3rdparty/Vulkan-Headers"
  mv "$ff" "$s/3rdparty/fast_float"
  cp -R "$(vk_headers_dir)" "$s/3rdparty/Vulkan-Headers"
  read_flags "$ROOT/flags/libplacebo.flags"; local common=("${FLAGS[@]}")
  read_flags "$APPLE/flags/libplacebo.apple.flags"
  meson_build libplacebo "$s" "${common[@]}" "${FLAGS[@]}"
  license libplacebo "$s/LICENSE"
  license fast_float "$s/3rdparty/fast_float/LICENSE-MIT"
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
    if [[ $f == --disable-* ]] && ! grep -qE -- "--(en|dis)able-${f#--disable-}([ =]|$)" <<<"$help"; then
      echo "ffmpeg: skipping $f (not an option of FFmpeg $(pin_version ffmpeg))" >>"$WORK/notes.txt"
      continue
    fi
    common+=("$f")
  done
  read_flags "$ROOT/flags/ffmpeg.apple.flags"; local apple=("${FLAGS[@]}")
  case $ARCH in arm64) arch=aarch64 ;; x86_64) arch=x86_64 ;; esac
  b="$BUILD/ffmpeg"
  rm -rf "$b"; mkdir -p "$b"
  (cd "$b" && run_logged ffmpeg env -u CC -u CFLAGS -u LDFLAGS "$s/configure" --prefix="$PREFIX" \
    --enable-cross-compile --target-os=darwin --arch="$arch" \
    --cc="$CC_BIN" --cxx="$CXX_BIN" --objcc="$CC_BIN" --ar="$AR_BIN" --ranlib="$RANLIB_BIN" \
    --strip="$STRIP_BIN" --nm="$(xcrun --sdk "$SDK" -f nm)" --x86asmexe="$NASM" \
    --sysroot="$SYSROOT" --pkg-config="$PKGCONF" \
    --extra-cflags="-target $TRIPLE -I$PREFIX/include" \
    --extra-objcflags="-target $TRIPLE" \
    --extra-ldflags="-target $TRIPLE -L$PREFIX/lib $HARDEN_LDFLAGS" \
    --install-name-dir="$PREFIX/lib" \
    "${common[@]}" "${apple[@]}")
  # --disable-autodetect makes configure drop requested features silently; fail instead.
  local cfg="$b/ffbuild/config.mak"
  for f in VIDEOTOOLBOX AUDIOTOOLBOX LIBDAV1D LIBVPX LIBOPUS LIBOPENMPT VULKAN ZLIB BZLIB ICONV LIBXML2; do
    require_grep "$cfg" "^CONFIG_$f=yes" "FFmpeg configure dropped $f"
  done
  if grep -q '^CONFIG_SECURETRANSPORT=yes' "$cfg"; then
    echo "ffmpeg ($SLICE): TLS via SecureTransport" >>"$WORK/notes.txt"
  elif [ "$OS" = macos ]; then
    die "FFmpeg configure dropped SecureTransport on $SLICE"
  else
    # The iOS SDK lacks SecIdentityCreate/SecItemImport, which FFmpeg's
    # SecureTransport backend requires; HTTPS on iOS goes through the app's
    # AVIO over URLSession (docs/05 4.1). No other TLS library is linked.
    echo "ffmpeg ($SLICE): no TLS protocol in FFmpeg (iOS SDK has no SecIdentityCreate); HTTPS via app AVIO" >>"$WORK/notes.txt"
  fi
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
  local extra=()
  [ "$OS" = macos ] && extra+=("-Dswift-flags=-target $TRIPLE")
  meson_build mpv "$s" "${common[@]}" "${apple[@]}" "${os[@]}" "${extra[@]}"
  local cfg="$BUILD/mpv/config.h"
  require_grep "$cfg" "#define HAVE_GPL 0" "mpv must be the LGPL build"
  for f in VULKAN LIBPLACEBO VIDEOTOOLBOX_PL; do
    require_grep "$cfg" "#define HAVE_$f 1" "mpv configure dropped $f"
  done
  license mpv "$s/LICENSE.LGPL" "$s/Copyright"
}
